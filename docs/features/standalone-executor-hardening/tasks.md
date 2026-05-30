# Task Breakdown — Standalone Executor Hardening

**Feature status:** `in_tdd` | **Stage:** `tasks` (draft) | Machine state lives in `tasks/T<n>.yaml`.

This breakdown implements the approved technical design: decouple the executor from the orchestrator by introducing a **dispatch service** (`runtime/dispatcher/`) that owns a dedicated Redis Stream, relocate spawning + credentials out of the orchestrator, gate executor git-logging behind `LOG_SINK`, and prove a bundled (`local-subprocess`) and a standalone (`local-docker`) topology run concurrently. Every task targets the **`workflow`** repo and changes exactly one repo. ABI-neutral — no `ExecutorResult` / `result.json` change.

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | ABI — DispatchJob payload + dispatch-stream contract + LOG_SINK env | — |
| T2 | 1 | Broker — `GET /registry-size` (completion-only; no dispatch state) | — |
| T3 | 2 | Executors — gate `flushLog` on `LOG_SINK` (claude + hermes) | T1 |
| T4 | 2 | Dispatcher service — own dispatch stream, spawn, creds, idempotency | T1, T2 |
| T5 | 2 | Orchestrator — `QueueDispatchAdapter`, drop socket/creds, reconciler | T1 |
| T6 | 3 | Compose + dev wiring — `local-docker` stack + `.env` templates | T3, T4, T5 |
| T7 | 4 | Integration + concurrent-coexistence parity test | T6 |

---

## T1 — ABI: DispatchJob payload + dispatch-stream contract + LOG_SINK env

### Description

Freeze the contracts every other task depends on, in `runtime/abi/`. This is the schema-freezing task — T3, T4, and T5 are all blocked on it.

Add to the ABI (`runtime/abi/src/types.ts` + `runtime/abi/docs/abi-spec.md`):

- **`DispatchJob` type** — the credential-free payload the orchestrator `XADD`s and the dispatcher consumes (per technical design §4 "DispatchJob payload"):
  ```
  { handle, nonce, kind,                                   // kind ∈ impl | review-fix | rebase
    task_id, feature_id, workspace_id,
    task_repo_url, task_repo_branch, task_base_branch, task_repo_base_branch,
    mgmt_repo_url, executor_workdir,
    callback_url,                                          // broker completion endpoint
    budget_tokens?, implementation_model?, enqueued_at }
  ```
  Secrets (`GITHUB_TOKEN`, `SSH_PRIVATE_KEY`) are **explicitly not** fields on this type — document that the dispatcher injects them.
- **Dispatch-stream contract** — the Redis Stream key and consumer-group name, defined once here as named constants so the orchestrator (`XADD`) and dispatcher (`XREADGROUP`) agree. Also document the DLQ stream key.
- **`LOG_SINK` runner env entry** — add `LOG_SINK` (`git | none`) to the runner env contract in `abi-spec.md`. Default `git` (bundled, unchanged); `none` set by the dispatcher on the standalone path.

**No change to `ExecutorResult`** — this feature is ABI-neutral. The `result.json` schema is untouched.

Key acceptance criteria:
- `DispatchJob` type exported from `runtime/abi`; carries no secret fields.
- Dispatch-stream key + consumer-group name + DLQ key are named constants in the ABI, not string literals scattered across services.
- `LOG_SINK` documented in the runner env contract with `git` as the default.
- `ExecutorResult` / `result.json` unchanged — verified by type diff.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read `runtime/abi/src/types.ts` and `runtime/abi/docs/abi-spec.md`; locate the runner env contract table and the executor I/O types
- [ ] Add the `DispatchJob` interface (fields above); add a doc comment stating secrets are injected by the dispatcher, never carried on the payload
- [ ] Add dispatch-stream constants: stream key, consumer-group name, DLQ stream key
- [ ] Add `LOG_SINK` (`git | none`, default `git`) to the runner env contract in `abi-spec.md`
- [ ] Confirm `ExecutorResult` is unchanged (ABI-neutral); note this explicitly in `abi-spec.md`
- [ ] Run the abi package build/tests (`npx tsc --noEmit`, unit tests)

---

## T2 — Broker: `GET /registry-size` (completion-only; no dispatch state)

### Description

Add a single read endpoint to the Go broker (`runtime/broker/`): **`GET /registry-size`**, returning the count of in-flight (registered, not-yet-acked) handles. The dispatcher reads it to enforce the global spawn cap, resolving the `dockerInFlight` in-process-counter tech debt carried from `platform-byo-executor`.

This task is deliberately narrow. Per technical design §4, the **broker does not host the dispatch queue or any dispatch state** — there is **no `dispatched` flag**, no dispatch endpoints. The dispatch stream lives in Redis owned by the dispatcher; terminal dispatch failure reaches the orchestrator as a synthetic `failed` completion through the existing `/callback`. The completion queue + sorted-set peek-and-lock store are otherwise unchanged.

T2 is independent of the `DispatchJob` schema, so it runs in parallel with T1.

Key acceptance criteria:
- `GET /registry-size` returns an integer count of currently-registered, un-acked handles.
- Count reflects the live sorted-set registry state (register increments the observable set; ack/orphan-sweep removes it).
- No `dispatched` flag, no dispatch endpoints, no dispatch state added to the broker.
- Existing completion-broker behaviour (register, `/callback`, `listCompleted`, ack, visibility-timeout reclaim, orphan sweep) is unchanged.

### Required skills

- go-best-practices

### Subtasks

- [ ] Read `runtime/broker/internal` + `cmd`; locate the HTTP route registration and the sorted-set registry store
- [ ] Add a store method that returns the count of registered, un-acked handles
- [ ] Wire `GET /registry-size` to return that count as JSON
- [ ] Add a broker unit test: register N handles → `registry-size` == N; ack one → N-1
- [ ] Confirm no `dispatched` flag / dispatch endpoint was introduced (scope guard)
- [ ] `golangci-lint run` (zero errors) + `go test ./...`

---

## T3 — Executors: gate `flushLog` on `LOG_SINK` (claude + hermes)

### Description

In **both** executors (`runtime/executors/claude/src/flush-log.ts` and `runtime/executors/hermes/src/flush-log.ts`), gate the git log flush on the `LOG_SINK` env var frozen in T1:

- `LOG_SINK=git` (default, bundled `local-subprocess` path) — keep today's behaviour byte-for-byte: flush JSONL to the management git repo under `docs/features/<featureId>/logs/<taskId>/`.
- `LOG_SINK=none` (standalone `local-docker` path) — `flushLog` becomes a no-op for the git write; logs go to stdout (captured by the dispatcher / `docker logs`).

Both executors are driven by the same runner-wrapper over the same ABI, so the gating must be implemented identically in both and the default must be `git` when the var is absent (preserves bundled behaviour for any caller that doesn't set it). No `result.json` change — this is the executor side of the ABI-neutral log-sink decision (technical design §3.3 option A).

Single repo (`workflow`): both executor directories live under `runtime/executors/` in the same repo, so this is one task, not two.

Key acceptance criteria:
- `LOG_SINK=none` → neither executor writes to the management repo; log lines still reach stdout.
- `LOG_SINK=git` or unset → both executors retain today's git-flush behaviour unchanged.
- No change to `result.json` or agent behaviour.
- Identical gating logic in claude and hermes (no drift between the two).

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read both `flush-log.ts` files; note any existing `LOG_SINK_ENABLED`-style guard in hermes and reconcile to the single `LOG_SINK=git|none` contract from T1
- [ ] Gate the git write on `LOG_SINK`: `none` → no-op (stdout only); `git`/absent → existing behaviour
- [ ] Ensure stdout logging still occurs on the `none` path (do not silence logs, only the git flush)
- [ ] Apply the identical change to both claude and hermes
- [ ] Unit tests in both packages: `none` → no git ops asserted; `git`/unset → git flush asserted (extend existing `flush-log.test.ts`)
- [ ] Run both executor test suites

---

## T4 — Dispatcher service: own dispatch stream, spawn, credentials, idempotency

### Description

Create the new `runtime/dispatcher/` service (sibling of `broker`/`orchestrator`/`executors`), per technical design §4. This is the core of the decoupling. The dispatcher:

- **Owns the dispatch Redis Stream** — consumes jobs via `XREADGROUP` (consumer group from T1's contract); redelivers stuck entries via `XAUTOCLAIM`; routes a job to the **dispatch DLQ** after K deliveries.
- **Relocates `DockerRunAdapter`** out of the orchestrator (`runtime/orchestrator/src/executor/docker-run.ts` → dispatcher) and holds the `CredentialPort` (`EnvCredentialAdapter`). It injects `GITHUB_TOKEN` / `SSH_PRIVATE_KEY` via `-e` at spawn and sets `LOG_SINK=none`.
- **Verifies and reconciles the `EXECUTOR_WORKDIR` vs `/workspace` bind-mount mismatch** (product-spec issue #4c): `EXECUTOR_WORKDIR` is the host path `<workspacesRoot>/exec-<handle>` while the volume bind-mounts at `/workspace`, so the executor may be writing to the container's ephemeral layer with the bind-mount unused. Determine the real behaviour and reconcile so the executor's workdir and the bind-mount agree.
- **Idempotency / no double-spawn** — acquire a **per-handle spawn lock before `docker run`**: `SET dispatch:lock:<handle> <owner> NX PX <ttl>` with `ttl` comfortably greater than worst-case `docker run` + image-pull time. Only the lock winner spawns; a loser skips and `XACK`s. The `platform.handle=<handle>` container-label check remains a cheap backstop for post-spawn redelivery. This closes the TOCTOU window where the orchestrator reconciler re-enqueues while a spawn is mid-flight (technical design §4 "Idempotency / no double-spawn").
- **Enforces the global spawn cap** by reading the broker `GET /registry-size` (T2).
- `XACK`s after a successful spawn.
- **On terminal dispatch failure** (DLQ after K deliveries) posts a **synthetic `failed` completion** to the broker `/callback` for that `handle`/`nonce` — the same channel the crash safety-net uses — so the orchestrator learns through the normal completion path. No dispatched-vs-not bookkeeping at the orchestrator.

Key acceptance criteria:
- Dispatcher consumes the dispatch stream via a consumer group and `XACK`s after spawn.
- `XAUTOCLAIM` redelivers stuck entries; after K deliveries the job goes to the DLQ.
- Per-handle `SET NX PX` spawn lock guarantees exactly one container even when two dispatchers race on a redelivered/re-enqueued job; lock TTL exceeds worst-case spawn time.
- Creds injected only by the dispatcher; `LOG_SINK=none` set on every standalone spawn.
- `EXECUTOR_WORKDIR` / bind-mount mismatch verified and reconciled (executor writes land on the bind-mounted volume, not the ephemeral layer).
- Global spawn cap honoured via broker `registry-size`.
- DLQ'd job posts a synthetic `failed` completion to `/callback`.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Scaffold `runtime/dispatcher/` (package, entrypoint, Dockerfile) as a sibling service
- [ ] Implement dispatch-stream consumer: `XREADGROUP` on the T1 stream key + consumer group; `XAUTOCLAIM` redelivery; DLQ after K deliveries
- [ ] Relocate `DockerRunAdapter` from the orchestrator into the dispatcher; move `EnvCredentialAdapter` (`CredentialPort`) alongside it
- [ ] Inject `GITHUB_TOKEN`/`SSH_PRIVATE_KEY` via `-e` and set `LOG_SINK=none` at spawn
- [ ] Verify the `EXECUTOR_WORKDIR` (host `exec-<handle>`) vs `/workspace` bind-mount behaviour; reconcile so executor writes hit the bind-mounted volume
- [ ] Implement per-handle spawn lock `SET dispatch:lock:<handle> <owner> NX PX <ttl>` before `docker run`; loser skips + `XACK`s; choose `ttl` > worst-case spawn+pull
- [ ] Keep `platform.handle=<handle>` label check as the post-spawn backstop
- [ ] Read broker `GET /registry-size`; enforce the global spawn cap before spawning
- [ ] `XACK` after a successful spawn
- [ ] On DLQ (terminal failure), POST a synthetic `failed` completion to the broker `/callback` for the handle/nonce
- [ ] Unit tests: consume + `XAUTOCLAIM` redelivery + DLQ; spawn-lock exactly-one-winner under concurrency; cap enforcement; synthetic-failed-completion-on-DLQ
- [ ] Run dispatcher test suite

---

## T5 — Orchestrator: `QueueDispatchAdapter`, drop socket/creds, dispatch reconciler

### Description

Make the orchestrator unprivileged on the `local-docker` path, per technical design §4. The orchestrator stops spawning and stops holding credentials; it only enqueues.

- **`QueueDispatchAdapter`** — implement the `ExecutorPort` so `submit()` becomes an `XADD` of a `DispatchJob` (T1 schema) to the dispatch stream (T1 stream key). The orchestrator gains a Redis client for the dispatch stream (Redis access is infra, not host privilege — the unprivileged-orchestrator goal still holds).
- **`createLocalDockerProfile`** — drop `DockerRunAdapter`, `EnvCredentialAdapter`, and the Docker socket from this profile (they now live in the dispatcher). `local-subprocess` is **untouched**.
- **Register handle+nonce before enqueue** — the orchestrator owns the broker relationship and the claim already happened in `claim.ts`; it registers `handle`+`nonce` with the broker, then `XADD`s the job carrying them.
- **Dispatch reconciler** in the poll loop — a backstop for the one case the dispatch stream can't self-heal: *no dispatcher alive at all* (job sits unclaimed, nothing `XAUTOCLAIM`s it). For an `in_progress` task with a persisted handle and **no completion past `EXECUTION_DEADLINE`**, re-enqueue (idempotent — T4's spawn lock + label guard prevent double-spawn) up to N times, then set `blocked`.

Key acceptance criteria:
- `ExecutorPort.submit()` on `local-docker` performs an `XADD` of a credential-free `DispatchJob`; no `docker run`, no Docker socket, no credential resolution in the orchestrator.
- `createLocalDockerProfile` no longer wires `DockerRunAdapter` / `EnvCredentialAdapter` / socket; `local-subprocess` profile is byte-for-byte unchanged.
- Handle+nonce registered with the broker before the `XADD`.
- Reconciler re-enqueues a never-dispatched job after `EXECUTION_DEADLINE`, capped at N retries, then `blocked` — and relies on T4 idempotency to avoid double-spawn.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read `runtime/orchestrator/src/executor/` (`factory.ts`, `docker-run.ts`), the profile bootstrap (`createLocalDockerProfile`), and `task/claim.ts` / handle-registration path
- [ ] Implement `QueueDispatchAdapter` (`ExecutorPort` → `XADD` to the T1 dispatch stream); add the Redis client
- [ ] Update `createLocalDockerProfile` to use `QueueDispatchAdapter` and drop `DockerRunAdapter`, `EnvCredentialAdapter`, and the socket
- [ ] Ensure handle+nonce are registered with the broker before enqueue; build the `DispatchJob` payload (no secrets)
- [ ] Implement the dispatch reconciler in the poll loop: no-completion-by-`EXECUTION_DEADLINE` → re-enqueue (≤ N), then `blocked`
- [ ] Confirm `local-subprocess` profile and bundled behaviour are unchanged
- [ ] Unit tests: `QueueDispatchAdapter` `XADD`; profile wiring no longer references socket/creds; reconciler state machine (re-enqueue ≤ N then blocked)
- [ ] Run orchestrator test suite

---

## T6 — Compose + dev wiring: `local-docker` stack + `.env` templates

### Description

Wire the dev infrastructure so the decoupled flow runs end-to-end and a bundled orchestrator can run alongside a standalone one, per technical design §4 + §8.

- `local-docker` compose stack gains the **`dispatcher`** service; `redis` + `broker` already present. The **`orchestrator` loses the Docker socket mount** (it no longer spawns).
- The bundled `local-subprocess` compose path keeps working unchanged.
- `.env.template` gains the dispatch-stream / `LOG_SINK` / dispatcher env (no MinIO, no object store — descoped to `executor-log-object-storage`).
- Topology is selected per orchestrator instance via `RUNTIME_PROFILE` (no global switch), enabling bundled ∥ standalone coexistence.

Single repo (`workflow`): compose files and `.env.template` live in the workflow repo.

Key acceptance criteria:
- `docker compose` brings up redis + broker + dispatcher + orchestrator for `local-docker`; orchestrator has no socket mount.
- `local-subprocess` bundled compose still starts and runs unchanged.
- `.env.template` documents the new dispatcher / dispatch-stream / `LOG_SINK` vars; no MinIO entries.
- Two orchestrator services with different `RUNTIME_PROFILE` can be declared and started side by side.

### Required skills

-

### Subtasks

- [ ] Locate the `local-docker` and `local-subprocess` compose files + `.env.template` in the workflow repo
- [ ] Add the `dispatcher` service to the `local-docker` stack (image/build, redis + broker deps, credential env, socket mount on the dispatcher)
- [ ] Remove the Docker socket mount from the `orchestrator` service in `local-docker`
- [ ] Add dispatch-stream / `LOG_SINK` / dispatcher vars to `.env.template`; confirm no MinIO/object-store entries
- [ ] Provide a compose arrangement that runs a bundled (`local-subprocess`) and a standalone (`local-docker`) orchestrator concurrently (distinct `RUNTIME_PROFILE`, distinct `WORKSPACES_ROOT`)
- [ ] Smoke-start both stacks locally to confirm services come up

---

## T7 — Integration + concurrent-coexistence parity test

### Description

Prove the feature's load-bearing requirements end-to-end with the full stack wired (T6), per technical design §8 and the product-spec success criteria.

Scenarios to cover:
- **Decoupled flow** — a task driven task-in → `result.json`-out over `local-docker` with the orchestrator holding no spawn privilege (no socket, no creds): claim → register → `XADD` → dispatcher spawn → executor → `/callback` → orchestrator drain → FSM advance.
- **Concurrent coexistence** — a bundled (`local-subprocess`) orchestrator+executor and a standalone (`local-docker`) executor run **at the same time on the same host** without contending on container names, networks, host workspace dirs, or broker handles. Verified, not assumed.
- **No mgmt-repo log writes on the standalone path** — `LOG_SINK=none` executor produces stdout logs and writes nothing to the management repo; the bundled path still git-flushes.
- **Concurrency hazards:**
  - (a) **dispatcher-crash redelivery** → `XAUTOCLAIM` re-delivers, exactly one container (no double-spawn).
  - (b) **reconciler re-enqueue racing a slow in-progress spawn** across M:N dispatchers → exactly one container via the per-handle spawn lock. The induced spawn must be slow enough to actually exercise the lock (not just the label backstop).
  - (c) **lost dispatch / no dispatcher alive** → orchestrator reconciler re-enqueues after `EXECUTION_DEADLINE`; capped retries then `blocked`.
- **Unprivileged orchestrator** — assert the orchestrator container has no Docker socket and resolves no credentials.

Key acceptance criteria:
- End-to-end `local-docker` decoupled flow passes.
- Bundled ∥ standalone run concurrently with no interference (verified).
- Standalone path writes no management-repo logs; bundled path unchanged.
- Hazards (a), (b), (c) all yield exactly one container / correct terminal state.
- Orchestrator verified to hold no spawn privilege.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Write the end-to-end `local-docker` decoupled-flow test (claim → enqueue → dispatch → execute → callback → drain)
- [ ] Add the concurrent-coexistence test: bundled ∥ standalone, assert no container-name/network/workspace/handle contention
- [ ] Assert standalone path writes no management-repo logs (and bundled still does)
- [ ] Induce dispatcher crash → assert `XAUTOCLAIM` redelivery yields exactly one container
- [ ] Induce a slow spawn + reconciler re-enqueue across two dispatchers → assert exactly one container via the spawn lock
- [ ] Induce lost dispatch (no dispatcher) → assert reconciler re-enqueue ≤ N then `blocked`
- [ ] Assert orchestrator container has no socket mount and resolves no creds
- [ ] Run the full integration suite green before PR
