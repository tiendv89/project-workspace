# Technical Design

## Feature
- Feature ID: `standalone-executor-hardening`
- Title: Standalone Executor Hardening — decoupled dispatcher + spawn-on-the-fly, mirroring prod in `local-docker`

> Phase 1 (design). Builds directly on `runtime-portable-architecture` (done) and resolves a tech-debt item carried in `platform-byo-executor` (broker `registry-size` / in-process `dockerInFlight`). Canonical prior reasoning: `docs/features/runtime-portable-architecture/discussion-orchestrator-architecture.md`.
>
> **Scope note:** persistent log storage (S3/MinIO, per-run `result.json` link, `runs[]` schema) was descoped to feature **`executor-log-object-storage`** (same branch). This feature only takes the standalone executor's logs *off* the management repo; it is ABI-neutral.

## Design principles (from product owner)

1. **Orchestrator owns the workflow, nothing else.** Strip from the orchestrator everything not about workflow state: direct container spawning, the Docker socket, and credential handling all move out.
2. **Executor is standalone and isolated.** It receives an already-claimed task, materialises its own repos, runs the agent, writes `result.json`. On the standalone path it logs to **stdout** (no management-repo write); persistent log storage is a separate feature. It knows nothing about the orchestrator.
3. **Orchestrator and executor are decoupled — they never reference or call each other.** All communication is indirect, through two infrastructure queues: a **dispatch queue** (orchestrator → dispatcher → executor spawn) and the existing **completion broker** (executor → broker → orchestrator drain).
4. **Dev mirrors prod.** The `local-docker` profile gains the dispatcher so its data flow is component-identical to production; only the spawn adapter (`DockerRunAdapter` → future `K8sJobAdapter`) differs.

## 1. Current state

The runtime is portable (ports/adapters/profiles, async submit/reap) after `runtime-portable-architecture`:

- **Profiles** selected by `RUNTIME_PROFILE` at startup (`runtime/orchestrator/src/main.ts:253`, default `local-subprocess`): `local-subprocess` (bundled — in-process broker, `SubProcessAdapter`) and `local-docker` (`DockerRunAdapter` + Go `HttpBrokerAdapter` + Redis).
- **Claim is orchestrator-owned and the executor is claim-agnostic** — status→`in_progress` + claim commit/push in `runtime/orchestrator/src/task/claim.ts` (`:281`, `:305-325`); executor spawned only if the claim is won (`main.ts:331-344`).
- **`local-docker` today couples the orchestrator to infra:** the orchestrator itself runs `docker run` via a mounted Docker socket (`DockerRunAdapter`, `runtime/orchestrator/src/executor/docker-run.ts`), resolves credentials (`EnvCredentialAdapter`, `runtime/orchestrator/src/infra/credential/env.ts`) passing `GITHUB_TOKEN`/`SSH_PRIVATE_KEY` as `-e` vars, and tracks spawn concurrency with an **in-process `dockerInFlight` counter** that resets on restart and can't be shared across orchestrators (tech debt from `platform-byo-executor`; correct fix is a broker `registry-size` endpoint).
- **Completion broker** (Go, `runtime/broker/`) is Redis-backed using a **sorted-set peek-and-lock** store (XREADGROUP/XACK semantics with explicit `lockMs`), reached over HTTP. Runner posts `{handle, nonce, result}` to `/callback`; any orchestrator drains via `listCompleted` (opportunistic M:N).
- **Executor** (`runtime/executors/claude/`) self-materialises its repos (`materializeRepo`, `index.ts`) into per-handle `exec-<handle>` workdirs, runs the agent, writes `result.json`, and **flushes logs to the management git repo** via `flushLog()` (`runtime/executors/claude/src/flush-log.ts`).
- The **runner wrapper** (`runtime/runner-wrapper/runner.js`) is the platform entrypoint in every profile.

Repo boundary: all of the above is in the **`workflow`** repo (`git@github.com:tiendv89/agent-workflow.git`).

## 2. Problem framing

**What must change:**
- The orchestrator must stop spawning executors directly. It enqueues a dispatch job; a new **dispatch service** spawns. The orchestrator runs unprivileged (no Docker socket, no credentials).
- On the standalone path, the executor must stop writing logs to the management repo. In this feature that means **disabling the git flush** (logs go to stdout, captured by the dispatcher); persistent storage is `executor-log-object-storage`.
- `local-docker` must mirror the production data flow (orchestrator → queue → dispatcher → executor → broker → orchestrator).

**What must remain stable:**
- The **`local-subprocess` (bundled) profile is untouched** and keeps working — including its git logging.
- The executor's agent-running behaviour, prompts, and `result.json` are unchanged — **this feature is ABI-neutral**.
- The claim protocol and workflow FSM stay orchestrator-owned.

**Fixed assumptions:** ports/adapters/profiles model is the substrate; the executor is already claim-agnostic; production k8s is **out of scope** (the dispatcher's spawn-adapter seam is kept clean for a future `K8sJobAdapter`; whether the prod orchestrator runs as a k8s CronJob is a later decision).

## 3. Options considered

### 3.1 Dispatch transport
- **A. Extend the existing broker service with a dispatch queue (chosen).** Orchestrator enqueues via broker HTTP (`POST /dispatch`); the dispatcher consumes via `POST /dispatch/claim` (peek-and-lock with `lockMs`) + `POST /dispatch/ack`. Reuses the broker's Redis sorted-set store and HTTP surface — one queue authority for both directions.
  - *Pros:* zero new infra; identical, already-tested peek-and-lock/redelivery semantics; only the broker touches Redis. *Cons:* broker gains a second responsibility (mitigated — same store, additive endpoints).
- **B. Dispatcher reads Redis directly (native Streams).** *Cons:* a second component touching Redis; diverges from the broker's deliberate sorted-set store.
- **C. External queue (NATS / RabbitMQ / SQS).** *Cons:* new infra for no capability we lack; a future adapter can swap it.

### 3.2 Where credentials live
- **A. Dispatcher is the sole credential holder (chosen).** `CredentialPort` moves out of the orchestrator into the dispatcher. Dev: dispatcher holds env and injects `-e` at spawn. Prod (future): the dispatcher creates a Job whose spec **references Secret names**; the kubelet injects. The **dispatch-job payload carries no secrets.**
- **B. Orchestrator resolves creds into the job payload.** *Rejected* — re-privileges the orchestrator and puts secrets on the queue.

### 3.3 Executor log handling (this feature only)
- **A. Config-gated git flush; off on standalone (chosen).** `LOG_SINK=git|none` injected at spawn. `local-subprocess` defaults to `git` (unchanged); the dispatcher sets `none` for `local-docker`, so the executor logs to stdout only. ABI-neutral, no new infra.
- **B. Build the S3 sink now.** *Rejected/descoped* — that is feature `executor-log-object-storage`; not on the critical path for proving the decoupled architecture.
- **C. Keep git flush on `local-docker`.** *Rejected* — keeps the management-repo coupling and is pointless in an ephemeral container with a read-only clone.

### 3.4 Dispatcher topology
- **A. Shared dispatch queue, a pool of stateless dispatchers (chosen).** Any dispatcher consumes any job (M:N), mirroring the broker's opportunistic drain. Global spawn concurrency via the broker `registry-size` endpoint (resolves the `dockerInFlight` debt).
- **B. One dispatcher per orchestrator.** *Rejected* — re-couples orchestrator and spawn lifecycle.

## 4. Chosen design

### Data flow (`local-docker`, mirrors prod)
```
orchestrator                      broker (Redis)                   dispatcher                 executor (ephemeral)
  │ claim task (git)                   │                               │                            │
  │ broker.register(handle,nonce) ───► │ handle: registered            │                            │
  │ POST /dispatch {job, no secrets}─► │ dispatch queue (peek-lock)    │                            │
  │                                    │ ◄── POST /dispatch/claim ──────│                            │
  │                                    │                               │ inject creds + LOG_SINK=none│
  │                                    │                               │ docker run exec-<handle> ─►│ materialise repos
  │                                    │ ◄── mark handle dispatched ────│ POST /dispatch/ack         │ run agent (logs → stdout)
  │                                    │ ◄──────── POST /callback {handle,nonce,result} ────────────│ write result.json
  │ ◄── listCompleted (drain) ─────────│                               │                            │ (runner posts, exits)
  │ record result; advance FSM         │                               │
  │ broker.ack ───────────────────────►│ handle: acked                 │
```
The orchestrator and executor never address each other. The orchestrator's `ExecutorPort.submit()` becomes **enqueue** (`QueueDispatchAdapter`); the relocated `DockerRunAdapter` lives in the dispatcher. `result.json` is unchanged.

### New / changed components (all in `workflow` repo)

- **`runtime/abi/`** — new `DispatchJob` type (payload below). New `LOG_SINK` entry in the runner env contract. **No change to `ExecutorResult`** (ABI-neutral).
- **`runtime/broker/`** (Go) — dispatch queue endpoints: `POST /dispatch` (enqueue), `POST /dispatch/claim` (peek-and-lock, `lockMs`), `POST /dispatch/ack`, dispatch DLQ after K redeliveries; `POST /dispatch/mark` to flip handle `registered`→`dispatched`; and **`GET /registry-size`** (resolves the `dockerInFlight` debt). Same Redis sorted-set store.
- **`runtime/dispatcher/`** (new folder, sibling of `broker`/`orchestrator`/`executors`) — consumes the dispatch queue; holds `DockerRunAdapter` + `CredentialPort`; injects creds + `LOG_SINK=none`; **idempotency guard** (skip if a container labelled `platform.handle=<handle>` exists); enforces the global spawn cap via `registry-size`; marks `dispatched`; acks / routes to DLQ.
- **`runtime/orchestrator/`** — `QueueDispatchAdapter` (ExecutorPort → `POST /dispatch`); `createLocalDockerProfile` drops `DockerRunAdapter`, `EnvCredentialAdapter`, and the Docker socket; **dispatch reconciler** in the poll loop; registers handle+nonce before enqueue. No log-link persistence (descoped).
- **`runtime/executors/claude/`** — `flushLog` becomes a no-op when `LOG_SINK=none` (logs to stdout); `git` (default) keeps today's behaviour for the bundled path. No `result.json` change.
- **Compose** — `local-docker` stack gains `dispatcher`; `redis` + `broker` already present; `orchestrator` loses the socket mount. No MinIO. `local-subprocess` compose unchanged.

### DispatchJob payload (credential-free)
```
{ handle, nonce, kind,                                   // identity + dispatch discriminator (impl|review-fix|rebase)
  task_id, feature_id, workspace_id,
  task_repo_url, task_repo_branch, task_base_branch, task_repo_base_branch,
  mgmt_repo_url, executor_workdir,
  callback_url,                                          // broker completion endpoint
  budget_tokens?, implementation_model?, enqueued_at }
```
Secrets (`GITHUB_TOKEN`, `SSH_PRIVATE_KEY`) are **not** in the payload — the dispatcher injects them.

### Dispatch reliability (failure surface from async dispatch)
- **Handle lifecycle at the broker:** `registered` (orchestrator) → `dispatched` (dispatcher) → `completed` (callback) → `acked`.
- **Idempotency:** dispatcher checks for an existing `platform.handle=<handle>` container before spawning → redelivery (after `lockMs`) never double-spawns. Key = `handle`.
- **Reconciler (orchestrator poll loop)** for `in_progress` tasks with a persisted handle:
  - handle **not `dispatched`** and age > `DISPATCH_DEADLINE` → re-enqueue (lost/stuck dispatch), up to N times, then `blocked`.
  - **`dispatched`** but no completion and age > `EXECUTION_DEADLINE` → executor crashed without callback; the broker safety-net/visibility timeout reclaims it → treat as failed and retry per `executor_max_retries`.
- **DLQ:** dispatch jobs that fail to spawn after K redeliveries land in a dispatch DLQ; orchestrator/operator alerted via the existing escalation channel.

### Concurrent-coexistence & isolation
- `local-subprocess` (bundled) and `local-docker` (dispatcher) run side by side: different `RUNTIME_PROFILE` per orchestrator service; bundled uses no containers/dispatcher/broker, so they don't contend.
- Handles are UUIDs (globally unique) → no broker-handle collisions. Distinct `WORKSPACES_ROOT` per instance. Container label `platform.handle=<handle>`.
- GitHub identity/rate-limit is shared in dev (acceptable, low volume); per-tenant token deferred to prod/`executor-credential-isolation`.
- Spawn concurrency is global (dispatcher + `registry-size`), not the old per-process counter.

### Resolutions to the product-spec open questions
| Q | Resolution |
|---|---|
| **Q1 Dispatch transport & queue** | Extend the **broker** with a dispatch queue (peek-and-lock, same Redis sorted-set store) + DLQ; payload above; `local-subprocess` untouched. |
| **Q2 Log sink** | `LOG_SINK=git\|none` injected at spawn. Standalone (`local-docker`) → `none` (stdout). Bundled → `git` (unchanged). **Persistent S3 storage descoped to `executor-log-object-storage`.** |
| **Q3 Claim location** | Already resolved — executor claim-agnostic; only the git-flush opt-out remains (Q2). |
| **Q4 Credentials & isolation** | Dispatcher is sole credential holder (dev: env inject; prod: Secret references). Co-resident isolation via per-profile/instance roots + UUID handles + label scoping. |
| **Q5 Dispatch reliability** | Handle register before enqueue (orchestrator); handle lifecycle states; idempotency by handle; reconciler with dispatch/execution deadlines; DLQ after K attempts. |

## 5. Dependency analysis

- **Internal:** `runtime-portable-architecture` (done) — ports/adapters/profiles + async submit/reap (satisfied). The broker `registry-size` endpoint (long-noted tech debt) is implemented here (T2).
- **Blocks downstream:**
  - `executor-log-object-storage` — persistent log storage builds on this feature's `LOG_SINK` seam and the dispatcher's credential-injection path.
  - `workflow-db` — the Go/Postgres orchestrator drives this same standalone executor over the dispatcher; its design must declare this dependency.
- **External/tooling:** Redis (already present). **No MinIO / object store in this feature.** No new managed services.
- **Out of scope (kept clean, not built):** `K8sJobAdapter` and the production k8s deployment (incl. whether the orchestrator runs as a CronJob); persistent logging.
- **Unresolved:** none blocking.

## 6. Parallelization / blocking analysis

External decisions: none unresolved — all open questions are answered in §4.

```
T1: ABI — DispatchJob payload + runner LOG_SINK env contract  (no ExecutorResult change)  (repo: workflow)
  └── Can begin now — no blockers
  │
  T2: Broker — dispatch queue (enqueue/claim/ack/DLQ + mark dispatched) + registry-size endpoint  (repo: workflow)
  T3: Executor — gate flushLog on LOG_SINK (none → stdout, git → unchanged)  (repo: workflow)
      └── T2 and T3 run in parallel
      └── BLOCKED on T1 (T2: DispatchJob schema frozen; T3: LOG_SINK env contract frozen)
      │
      T4: Dispatcher service (runtime/dispatcher/) — relocate DockerRunAdapter, hold CredentialPort,
      │   inject creds + LOG_SINK=none, idempotency guard, global cap via registry-size, mark dispatched, ack/DLQ  (repo: workflow)
      │   └── BLOCKED on T1 (DispatchJob payload), T2 (dispatch + registry endpoints must exist)
      │
      T5: Orchestrator — QueueDispatchAdapter, drop socket+credential adapter from local-docker profile,
          dispatch reconciler, register handle before enqueue  (repo: workflow)
          └── BLOCKED on T1 (payload), T2 (dispatch endpoints must exist)
          └── T4 and T5 run in parallel
          │
          T6: Compose + dev wiring — local-docker stack (redis, broker, dispatcher, orchestrator);
          │   keep local-subprocess bundled compose working; .env templates  (repo: workflow)
          │   └── BLOCKED on T3 (executor honours LOG_SINK), T4 (dispatcher service), T5 (orchestrator enqueue)
          │
          T7: Integration + parity test — bundled ∥ local-docker concurrently; prove decoupled flow,
              idempotency, reconciliation, unprivileged orchestrator, no mgmt-repo log writes on standalone path  (repo: workflow)
              └── BLOCKED on T6 (full stack wired)
```

Wave 1: **T1**. Wave 2: **T2 ∥ T3**. Wave 3: **T4 ∥ T5**. Wave 4: **T6**. Wave 5: **T7**.

## 7. Repository impact

| Repo (`workspace.yaml` id) | Why |
|---|---|
| `workflow` | All implementation: `runtime/abi` (T1), `runtime/broker` (T2), `runtime/executors/claude` (T3), `runtime/dispatcher` new (T4), `runtime/orchestrator` (T5), compose/env (T6), tests (T7). |
| `management-repo` | Only this feature's docs (design/tasks) — no implementation. |

Every task targets a single repo (`workflow`) — no cross-repo task.

## 8. Validation and release impact

- **Testing:** unit (`QueueDispatchAdapter`; dispatcher idempotency + concurrency cap; `flushLog` LOG_SINK gating; reconciler state machine); broker fixture parity for the new dispatch endpoints (mirror existing `broker-protocol/fixtures`); integration in T7 — bundled ∥ local-docker concurrently, end-to-end decoupled flow, induced dispatcher-crash redelivery (no double-spawn), induced lost-dispatch (reconciler re-enqueue).
- **ABI / compatibility:** **ABI-neutral** — no `result.json` change; `local-subprocess` byte-for-byte unchanged (git logging retained); no change to agent behaviour or prompts.
- **Migration/config:** new dev infra — `dispatcher` service + dispatch/LOG_SINK env in `.env.template`; orchestrator loses the Docker socket mount. No MinIO, no data migration.
- **Rollout:** purely additive — `local-docker` opt-in per orchestrator instance via `RUNTIME_PROFILE`; bundled remains the default/fallback. Production (k8s) deferred; spawn-adapter seam kept clean. **Known tradeoff:** until `executor-log-object-storage` lands, `local-docker` run logs are ephemeral (stdout / `docker logs` only) — not persisted or RAG-indexed.
- **Handoff:** unblocks `executor-log-object-storage` and `workflow-db`.
