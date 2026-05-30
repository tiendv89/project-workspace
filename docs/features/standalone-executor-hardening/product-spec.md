# Product Specification

## Feature
- Feature ID: `standalone-executor-hardening`
- Title: Standalone Executor Hardening — Harden `local-docker` Spawn-on-the-Fly for Concurrent Topologies

> Status: **draft** — pending human review. Authored as the prerequisite for `workflow-db` (Go orchestrator on Postgres). See "Relationship to other features".

## Problem

The agent runtime today always runs **bundled**: the orchestrator and the executor are launched together as one unit. This was fine while there was a single orchestrator. It is now the blocker for the next step of the platform.

We want to introduce a second orchestrator (Go, backed by Postgres — feature `workflow-db`) and run it **in parallel** with the existing TypeScript/git orchestrator during development and migration. Both orchestrators must be able to drive executors. With the executor welded to the orchestrator, there is no way to do this: the new orchestrator cannot reuse the existing, proven executor, and we would be forced to reimplement the executor in Go as well — doubling the rewrite surface and the divergence risk.

The executor's job (run agent work, write `result.json`) does not depend on which orchestrator dispatched it or on where workflow state lives. It should be a standalone component that **any** orchestrator can drive over the existing ABI / broker protocol.

The good news from investigation: this topology **already exists in design** as the `local-docker` profile — *"M:N multi-container topology. N orchestrators share a Redis-backed broker; each task gets its own executor container spawned via `docker run -d`."* The work of this feature is therefore not to invent a new model but to **harden `local-docker` so it works correctly** as the canonical unbundled, spawn-on-the-fly executor path, and to prove a standalone executor and the bundled path can run side by side.

## Execution model (settled decision)

The executor is **ephemeral and spawned on the fly — one fresh executor per task**, created at dispatch and destroyed at completion, via the `ExecutorPort` adapter seam. This is the chosen direction. Rationale:

- **Isolation / multi-tenancy.** Each task gets a clean sandbox: fresh filesystem, freshly-injected credentials, no residue, destroyed on exit. This is required for the multi-tenant end state and for running untrusted agent-generated code. (Multi-tenancy is a first-class platform requirement.)
- **Task duration makes cold-start negligible.** Agent tasks run minutes to hours; container/pod startup is seconds — under ~1–2% overhead, dominated anyway by repo clone + context warmup.
- **Scale-to-zero economics.** Bursty workloads cost nothing at idle and attribute cost cleanly per task/tenant.

**Rejected: long-running, multi-task workers.** A worker that processes successive tasks (a) leaks state/credentials across tasks and tenants, (b) requires a different *work-queue* dispatch fabric (the current broker is a *completion* broker, push-dispatch + orchestrator-owned claim), and (c) buys no m‑n capability the broker doesn't already provide. It is the wrong model for this workload.

**The only sanctioned form of "both":** a **warm pool of *disposable* executors** — pre-created, unassigned, kept warm to hide cold-start; each is assigned exactly one task and then **destroyed** (never reused across tasks) — plus **shared cache services** (e.g. git mirror/cache, RAG index, model proxy) for expensive warm state. Warm capacity for latency; never task reuse.

**Adapter seam is the portability contract.** Two seams: the orchestrator's `ExecutorPort.submit()` — now an *enqueue* (a `QueueDispatchAdapter`) — and the **dispatch service's spawn adapter** that turns a dequeued job into a running executor (`DockerRunAdapter` in dev, `docker run -d`). A future production substrate (Kubernetes Jobs) is a **new spawn adapter** (`K8sJobAdapter`) behind that seam — purely additive, no orchestrator-core change. Nothing in this feature may break or bypass either seam. See **Dispatch service** below.

**Topology selection is per orchestrator instance, via a flag — not a global mode.** Each orchestrator chooses its executor adapter from the existing profile mechanism: `RUNTIME_PROFILE` resolved through the bootstrap profile map (`portability-spec.md` Step 3 — `case "local-docker": return createLocalDockerProfile(...)`), set per service in docker-compose. "Bundled vs standalone" is effectively a profile choice already (`local-subprocess` ≈ bundled, in-process broker; `local-docker` ≈ standalone, shared Redis broker, M:N). Concurrent coexistence is therefore achieved by running two orchestrator services with different `RUNTIME_PROFILE` values at the same time — the flag *enables* the requirement. What is avoided is a single global switch that forces the whole deployment into one mode.

**Dispatch service — the orchestrator never spawns executors directly.** To reflect production and keep the orchestrator unprivileged, the orchestrator does **not** call `docker run` (or the k8s API) itself. It claims the task, registers the `handle`+`nonce` with the completion broker, then **enqueues a dispatch job** (carrying handle, nonce, and task references) onto a dispatch queue. A separate **executor dispatch service** dequeues the job and spawns the executor via a spawn adapter. Consequences:

- **The orchestrator runs unprivileged.** Spawn credentials — the docker socket in dev, k8s Job-create RBAC in prod — live *only* in the dispatch service, the single auditable credential holder. This resolves the docker-socket-on-orchestrator problem (known issue #2) **by design**, not by documentation.
- **Dev mirrors prod.** Orchestrator behaviour is identical in both; only the dispatch service's spawn adapter differs. `local-docker` becomes "dispatch service + `DockerRunAdapter`"; prod becomes "dispatch service + `K8sJobAdapter`" (downstream feature).
- **Symmetric queues, one Redis.** The dispatch queue (orchestrators → dispatchers, work out) and the existing completion broker (executors → orchestrators, results back) are two directions over the same Redis. Orchestrators and dispatchers are both stateless, M:N pools.
- **Code location.** The dispatch service is a folder in the workflow repo — `runtime/dispatcher/`, alongside `runtime/broker`, `runtime/orchestrator`, `runtime/executors` — not a separate repo.
- **Dev infrastructure.** The dev compose stack gains **MinIO** (the log object store) alongside Redis (completion broker + dispatch queue), the dispatch service, the orchestrator(s), and per-task executor containers.

This is a *relocation of the spawn mechanism plus a queue*, not an orchestrator rewrite: the existing `DockerRunAdapter` moves into the dispatch service; `ExecutorPort.submit()` becomes an enqueue.

## Goals

- **Introduce the executor dispatch service** (`runtime/dispatcher/`) for the unbundled path: the orchestrator enqueues dispatch jobs and runs **unprivileged**; the dispatch service dequeues, owns the spawn adapter, and is the sole holder of spawn credentials. Dev (`local-docker`) and prod differ only in that adapter. (`local-subprocess` does not use the dispatcher — see Non-goals.)
- **Make `local-docker` work correctly** as the unbundled, spawn-on-the-fly executor path: a standalone executor container spawned per task **by the dispatch service** via `DockerRunAdapter`, completion routed through the Redis-backed broker, drained opportunistically by any orchestrator (handle + single-use nonce, peek-and-lock, ack, visibility-timeout reclaim, crash safety-net, orphan sweep all proven correct under concurrency).
- Run the executor **fully unbundled** — driven purely over the ABI (`runtime/abi/docs/abi-spec.md`) and broker protocol (`runtime/portability-spec.md`), with **no orchestrator bundled into it**.
- Keep the executor in **TypeScript, unchanged in behaviour**. This feature changes *how it is launched and driven*, not what it does.
- Support **concurrent topologies on the same infrastructure**: a bundled orchestrator+executor (today's production path) and a standalone `local-docker` executor (driven by a new orchestrator) running **side by side at the same time**, isolated from each other. This is the load-bearing requirement — see Non-goals.
- **Preserve the `ExecutorPort` adapter seam** so a future Kubernetes profile (`K8sJobAdapter`) is purely additive.
- **Move executor logs to object storage (ABI change).** The executor uploads its run log to S3-compatible storage (MinIO in dev, S3 in prod) and returns the **log link in `result.json`** — an additive ABI change. The orchestrator records the per-run link as task metadata — a **list**, since a task has multiple runs (impl, fix, review) — git YAML today, Postgres later. The executor no longer writes logs to the management repo — removing its last management-repo coupling.

## Non-goals

- **Not a single global mode switch for the whole deployment.** Selecting the executor topology with a flag is *encouraged* — but **per orchestrator instance**, via the existing profile mechanism (`RUNTIME_PROFILE` + the bootstrap profile map, set per service in docker-compose), not one global toggle that forces the entire deployment into bundled-or-standalone. Per-instance profile selection is precisely what lets bundled and standalone coexist (see "Topology selection" in the execution model); a single global switch is what would prevent it.
- **Not the Kubernetes spawn adapter.** `K8sJobAdapter` and the production k8s deployment are a separate downstream feature. This feature builds the dispatch service + dispatch queue + the docker spawn adapter, and keeps the spawn-adapter seam clean for the k8s one.
- **Not changing `local-subprocess`.** It stays untouched as the current local-only, no-dispatcher fallback. The dispatch service and dispatch queue apply to the unbundled (`local-docker` / standalone) path only.
- **Not deciding the queue technology here.** Redis-stream vs dedicated queue, the dispatch-job payload schema, and retry/DLQ mechanics are deferred to the technical design.
- Not long-running / pooled multi-task workers (explicitly rejected above).
- Not building the Go orchestrator or the Postgres write path — that is `workflow-db`.
- Not changing the executor's agent-running behaviour or prompts. (The **only** `result.json` / ABI change is the additive per-run **log link** — see Goals.)
- Not removing the TypeScript orchestrator — that happens at `workflow-db` cutover, not here.

## Known correctness & security issues to address (from investigation)

The current `local-docker` path is the right shape but has gaps that "work correctly" must close (or explicitly defer to the k8s feature with a documented trust boundary):

1. **Log-sink coupling — RESOLVED by moving logs to object storage.** Today the executor flushes logs to the management *git* repo via `flushLog()` (JSONL under `docs/features/<featureId>/logs/<taskId>/`, `runtime/executors/claude/src/flush-log.ts`). New design: the executor uploads its run log to S3/MinIO and returns the link in `result.json`; the orchestrator stores the per-run link. This removes the executor's last management-repo write entirely (better than redirecting it). **In scope.**
2. **Docker-socket privilege — RESOLVED by the dispatch-service design.** The socket no longer lives on the orchestrator: only the **dispatch service** holds it (dev), and in prod the dispatch service uses namespaced k8s Job-create RBAC instead of any socket. The orchestrator runs unprivileged — it only talks to the queue. Remaining hardening: lock down the dispatch service itself (least-privilege socket access / tight RBAC scope).
3. **Secrets via env.** `EnvCredentialAdapter` passes `GITHUB_TOKEN` / `SSH_PRIVATE_KEY` as `-e` vars, visible via `docker inspect`. Note and align with `executor-credential-isolation`; harden or document.
4. **Shared host volumes & cleanup.** `workspacesDir` (per-handle `exec-<handle>`) and the briefing volume sit on a shared host path. Cleanup on the happy path exists — `runner.js` `rmSync`s `EXECUTOR_WORKDIR` after delivering the result, and `ack()`/orphan-sweep `docker rm` the container — so *residue* is largely handled. Gaps to close/verify: (a) on crash, `runner.js`'s `rmSync` is skipped (backstopped by `docker rm` in docker mode, but **subprocess mode leaves a populated host workdir**); (b) nothing `rmdir`s the host `exec-<handle>` mount dir itself (empty dirs accumulate); (c) **apparent mismatch** — `EXECUTOR_WORKDIR` is the host path `<workspacesRoot>/exec-<handle>` (`main.ts:414`, passed verbatim at `docker-run.ts:274`) while the volume is bind-mounted at `/workspace` (`docker-run.ts:301`), so in docker mode the executor seems to write to the container's ephemeral layer and the bind-mount goes unused — verify and reconcile. **Crucially, cleanup-after-finish addresses residue, not concurrent exposure:** during a run the workspace/briefing/cred files are host-visible to anything with host/socket access. k8s `emptyDir` (pod-scoped, auto-destroyed) fixes both residue *and* concurrent isolation later.
5. **Concurrent-coexistence correctness.** Bundled and standalone executors must not contend on container names, networks, host workspace dirs, or broker handles.

## Key open questions (to resolve in technical design)

1. **Dispatch transport & queue** — the orchestrator enqueues dispatch jobs; the dispatch service dequeues and spawns. RESOLVED: `local-subprocess` is **left untouched** as the local-only, no-dispatcher fallback (see Non-goals) — only the unbundled (`local-docker` / standalone) path uses the dispatcher. Deferred to technical design: queue technology (a Redis stream alongside the completion broker vs a dedicated queue), the dispatch-job payload schema, and the exact compose topology for running bundled + standalone concurrently.
2. **Log sink → object storage** — DECIDED: the executor uploads its run log to S3-compatible storage (MinIO in dev, S3 in prod) and returns the link in `result.json`; the orchestrator persists the per-run link. Deferred to technical design: the object-key scheme (e.g. `<workspaceId>/<featureId>/<taskId>/<handle>`), where S3/MinIO credentials are injected (the dispatch service as credential holder — cf. Q4), log retention/lifecycle, adding MinIO to the dev compose stack, and the **orchestrator-side task schema** for the per-run link (a list of `{run_kind, handle, log_url, at}`, since a task has multiple runs).
3. **Claim location** — RESOLVED: the executor is **already claim-agnostic**. The orchestrator owns the entire claim — status → `in_progress` and the claim commit/push happen in `runtime/orchestrator/src/task/claim.ts` (`:281`, `:305-325`); the executor is spawned only if the claim is won (`main.ts:331-344`) and receives an already-claimed branch (`ExecutorPortInput`, `main.ts:405-437`). The executor writes no task status. No claim extraction needed — only the log-sink move to object storage (item 2).
4. **Credentials & isolation** (finalize in technical design) — the dispatch service is the sole spawn-credential holder. Current leaning:
   - **Dev:** the dispatcher holds the env (creds) and injects them into the executor at spawn — i.e. today's `EnvCredentialAdapter` + `-e` injection, relocated from the orchestrator to the dispatcher. (Env stays `docker inspect`-visible — acceptable on the trusted dev host; known issue #3.)
   - **Prod:** credentials live in the **Job setup** — the dispatcher creates a k8s Job whose spec **references Secret names**, and the kubelet injects them into the pod (env/files/projected tokens). The dispatcher handles Secret *references*, not raw secret material.
   - Align with `executor-credential-isolation`. Still open: how two co-resident topologies are isolated (compute, working dirs, GitHub identity / rate limits).
5. **Dispatch reliability** (new failure surface from async dispatch) — (a) where `handle`+`nonce` register: RESOLVED to the **orchestrator, before enqueue** (it owns the broker relationship and the claim already happened there); the job payload carries them. (b) "enqueued but never spawned" reconciliation — extend the existing `persistHandle` crash-recovery: a handle with no executor and no completion past a deadline → re-dispatch or fail. (c) dispatch retry / dead-letter policy. (d) idempotency so a redelivered job never spawns two executors for one claim (key = `handle`).

## Success criteria

- The existing TS executor can be launched standalone and driven to completion (task in → `result.json` out) over the ABI via `local-docker`, with **no orchestrator bundled into it**.
- The orchestrator holds **no spawn privilege** (no docker socket, no cluster credentials): it enqueues dispatch jobs and the **dispatch service** performs all spawning.
- A bundled orchestrator+executor and a standalone `local-docker` executor run **concurrently on the same host** without interfering — verified, not assumed.
- The `local-docker` m‑n path is correct under concurrency: nonce auth, peek-and-lock drain, ack/visibility-timeout, crash safety-net, and orphan sweep all behave correctly with multiple orchestrators and multiple in-flight executors.
- The executor writes **no logs to the management repo**: each run's log is uploaded to object storage (S3/MinIO) and its link is returned in `result.json` and stored per run. The executor performs no workflow-state writes.
- The `ExecutorPort` seam is intact: a future `K8sJobAdapter` could be added without changing the orchestrator core.
- No behavioural change to agent work or prompts; the **only** `result.json` change is the additive per-run log link.
