# Tasks — runtime-portable-architecture

> Feature status: `in_tdd`. Stage status: `tasks` (draft — not yet approved).
> Machine-mutable state (status, depends_on, branch, pr, log) lives in `tasks/T<n>.yaml`.
> This document carries the narrative: descriptions, required skills, model overrides, and subtasks.

## Redeployment notes — keeping the running stack alive through the rollout

This section is the operational view of the rollout. It tells you, for each merged PR, whether you can redeploy in isolation without breaking your currently-running agents.

**Headline:** you can keep running `local-subprocess` end-to-end through every task except T5+T6, which must ship together. The new `local-docker` profile becomes available after T9 — it does **not** replace `local-subprocess`; it's a new option chosen at startup via `--profile`.

### Per-task impact

| Task  | Safe to redeploy in isolation? | What changes operationally                                                                                       | Cutover notes                                                                                                |
|-------|--------------------------------|------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| T1    | ✅ Yes                          | Nothing in the runtime path. New unused interfaces + fakes under `runtime/abi/`.                                  | None.                                                                                                         |
| T2    | ✅ Yes                          | Refactor of today's runtime through ports. Behaviour preserved bit-for-bit. Same image, same flow.                | Watch the test-suite parity check on the PR. Redeploy is a drop-in. Default profile is `local-subprocess`.    |
| T3    | ✅ Yes                          | Orchestrator binds a new HTTP port at startup (ephemeral by default). The broker is **dormant** — not yet wired into claims. | None for `local-subprocess` flow. Verify the port binding doesn't collide with anything else on the host.    |
| T4    | ✅ Yes                          | New file in repo (`runtime/runner-wrapper/`). Not invoked yet.                                                    | None.                                                                                                         |
| T5    | ⚠️ **Must ship with T6**        | Alone, `SubProcessAdapter` becomes async but the orchestrator's claim concern still expects blocking — **broken state**. | Do not merge T5 alone. Coordinate with T6 in the same merge window.                                            |
| T6    | ⚠️ **Must ship with T5**        | Together with T5, the orchestrator's loop becomes non-blocking — first real behaviour change of the rollout.       | **Drain in-flight tasks before redeploy.** Let any running executor children finish, then redeploy. Functionally equivalent after cutover; the cycle just no longer pauses on each executor. |
| T7    | ✅ Yes                          | New Go broker service binary + container image exist. Nothing talks to them yet — `local-subprocess` still uses the embedded `InMemoryBrokerAdapter`. | None for `local-subprocess`. Compose template doesn't reference the broker until T9.                          |
| T8    | ✅ Yes                          | New `DockerRunAdapter` exists. No profile uses it until T9.                                                       | None.                                                                                                         |
| T9    | ✅ Yes                          | `local-docker` profile becomes selectable. `local-subprocess` continues to work and stays the default.            | First run with `--profile local-docker` requires the `broker` and `redis` containers up (compose handles it). Subprocess users unaffected. |
| T10   | ✅ Yes                          | Documentation and `fake-orchestrator` harness updates only.                                                       | None.                                                                                                         |

### Continuity guarantees

- **Through T1 → T4 (inclusive):** redeploy at will. `local-subprocess` is unchanged operationally.
- **T5 + T6 together:** the only step that changes runtime semantics. Schedule a maintenance window or graceful drain.
  - Graceful drain procedure: stop accepting new claims, let in-flight executor children finish, then redeploy. Same pattern as today's restart procedure.
- **Through T7 → T8:** redeploy at will. The Go broker container can be built and even started, but `local-subprocess` doesn't touch it.
- **T9:** `local-docker` becomes available as an opt-in profile. Pick when ready by passing `--profile local-docker` at startup; `--profile local-subprocess` (or no flag) keeps today's flow.
- **T10:** docs and harness only.

### Recommended rollout cadence

1. Land T1–T4 in any order respecting dependencies. No agent disruption.
2. Coordinate T5 + T6 merge as a single rollout. Drain first.
3. Land T7, T8 in any order. No agent disruption.
4. Land T9. Decide separately when (and which agents) to switch to `local-docker`.
5. Land T10 to close out docs.

If at any point you want to roll back, you can revert any task PR independently except for T5/T6 — those revert as a pair.

## Index

| ID  | Wave | Title                                                                  | Depends on        |
|-----|------|------------------------------------------------------------------------|-------------------|
| T1  | 1    | Port interfaces + types + fake adapters                                | —                 |
| T2  | 2    | Extract today's adapters; wire `local-subprocess` profile              | T1                |
| T3  | 3a   | `CompletionBrokerPort` + `InMemoryBrokerAdapter` + HTTP receiver       | T2                |
| T4  | 3b   | Runner wrapper script (D6c)                                            | T1                |
| T5  | 3c   | `SubProcessAdapter` async submit/reap with broker integration          | T3, T4            |
| T6  | 3d   | Refactor orchestrator concerns + shared reap loop                      | T5                |
| T7  | 4a   | Redis-backed broker service (Go) + container                           | T3                |
| T8  | 4b   | `DockerRunAdapter`                                                     | T4, T6, T7        |
| T9  | 4c   | docker-compose template + bridge network                               | T7, T8            |
| T10 | 5    | Portability spec doc + fake-orchestrator harness + CLAUDE.md updates   | T9                |

All tasks land in the `workflow` repo. `repo: workflow` matches `workspace.yaml -> repos[].id`.

## Per-task dependency diagram

```
T1: Port interfaces + types + fake adapters
  └── Can begin now — no blockers
  │
T2: Extract today's adapters; wire local-subprocess profile
  └── BLOCKED on T1 (port interfaces must exist before adapters implement them)
T4: Runner wrapper script (D6c)
  └── BLOCKED on T1 (handle / nonce / completion schemas + the env contract
                      live in runtime/abi/)
  └── T2 and T4 run in parallel after T1
  │
  T3: CompletionBrokerPort + InMemoryBrokerAdapter + HTTP receiver
    └── BLOCKED on T2 (orchestrator core wired through port interfaces;
                        broker plugs into the same wiring)
    │
    T5: SubProcessAdapter async submit/reap with broker integration
      └── BLOCKED on T3 (broker contract + HTTP receiver in place;
                          register / listCompleted / ack are call sites)
      └── BLOCKED on T4 (wrapper script must exist to be spawned as the child)
    T7: Redis-backed broker service (Go) + container
      └── BLOCKED on T3 (broker HTTP contract + JSON fixtures pinned by the
                          reference InMemoryBrokerAdapter; T7 conforms via
                          black-box fixture replay)
      └── T5 and T7 run in parallel after T3 (T5 also waits on T4)
      │
      T6: Refactor orchestrator concerns + shared reap loop
        └── BLOCKED on T5 (subprocess adapter must work async end-to-end before
                            the orchestrator core's loop is rewired around it)
        │
        T8: DockerRunAdapter
          └── BLOCKED on T4 (wrapper script reused unchanged inside the container)
          └── BLOCKED on T6 (orchestrator concerns must already be async — otherwise
                              DockerRunAdapter has no user)
          └── BLOCKED on T7 (Redis broker must be reachable across containers
                              before M:N can be exercised)
          │
          T9: docker-compose template + bridge network
            └── BLOCKED on T7 (broker container image must exist for compose
                                to reference)
            └── BLOCKED on T8 (DockerRunAdapter must work for the compose template
                                to exercise it end-to-end)
            │
            T10: Portability spec doc + fake-orchestrator harness + CLAUDE.md
              └── BLOCKED on T9 (docs must reflect the shipped local-docker profile;
                                  fake-orchestrator harness mirrors the production
                                  contract)
```

**Wave-level summary:**
- **Wave 1 (T1)** unblocks everything. Single task.
- **Wave 2 (T2)** + Wave 3b (T4) run in parallel after T1.
- **Wave 3a (T3)** unblocks the rest of Wave 3 (T5, T6) and Wave 4's broker (T7).
- **Wave 4 (T7, T8, T9)** delivers the M:N profile.
- **Wave 5 (T10)** closes out docs/harness updates.

---

## T1 — Port interfaces + types + fake adapters

### Description
Define the full set of TypeScript port interfaces under `runtime/abi/` (or `runtime/orchestrator/ports/`) per the technical design's "The ports" table, plus the new `CompletionBrokerPort` (D7b) with peek-and-lock semantics. Define accompanying type schemas for `ExecutorHandle`, `ExecutorInput`, `ExecutorResult`, `ExecutorCompletion`, `HandleMetadata`, and the runner-callback payload. Add a fake adapter for every port (notably `FakeBrokerAdapter` — an in-memory queue with the same surface — used by hermetic core tests). No behaviour change.

This is the foundation Wave 2 onwards builds on. The interfaces here are the public contract; everything downstream implements them.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Define `ExecutorPort` interface (`submit`, optional `readResult`)
- [ ] Define `CompletionBrokerPort` interface (`register`, `listCompleted` peek+lock, `ack`, `nack`)
- [ ] Define `BriefingTransportPort`, `WorkflowStatePort`, `CredentialPort`, `WorkspacePullPort`, `EventEmitterPort`, `SchedulerPort`, `ClockPort`
- [ ] Define `ExecutorHandle`, `ExecutorInput`, `ExecutorResult`, `ExecutorCompletion`, `HandleMetadata` types
- [ ] Define the runner-callback HTTP payload shape (`{ handle, nonce, result }`)
- [ ] Implement `FakeBrokerAdapter` — in-memory queue with peek-and-lock + visibility timeout
- [ ] Implement fake adapters for every other port
- [ ] Bump `@workflow/runtime-abi` minor version
- [ ] Add `runtime/abi/README.md` listing every port and its purpose

---

## T2 — Extract today's adapters; wire `local-subprocess` profile

### Description
Refactor today's inline orchestrator code so each side effect goes through a port. Implement a real adapter for every port required by the `local-subprocess` profile. Define the profile factory and wire the orchestrator core to depend only on port interfaces. End of task: today's behaviour preserved bit-for-bit; no new external behaviour visible.

`CompletionBrokerPort` is wired with an empty no-op adapter at this point (T3 ships the in-memory implementation). The orchestrator's blocking spawn-and-await flow is unchanged in this wave; the broker port exists for type safety.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Implement `SubProcessAdapter` (Wave 2 version — preserves today's blocking flow)
- [ ] Implement `LocalFileBriefingAdapter`
- [ ] Implement `GitWorkflowStateAdapter`
- [ ] Implement `EnvCredentialAdapter`
- [ ] Implement `GitClonePullAdapter`
- [ ] Implement `StdoutJsonEmitter`
- [ ] Implement `SimpleSleepScheduler`
- [ ] Implement `RealClock`
- [ ] Define `local-subprocess` profile factory bundling these adapters
- [ ] Wire orchestrator core (claim / review-fix / workspace-PR concerns) to use port interfaces
- [ ] Run existing test suite; confirm behavioural parity with pre-refactor runtime
- [ ] No-op `CompletionBrokerPort` adapter satisfies the type system without changing flow

---

## T3 — `CompletionBrokerPort` + `InMemoryBrokerAdapter` + HTTP receiver

### Description
Implement the `CompletionBrokerPort` contract end-to-end with in-process state. Bind an HTTP route (`POST /callback`) on the orchestrator process at startup. The receiver validates the per-handle nonce against the in-flight registry and, on success, enqueues the completion onto the peek-and-lock queue. The reclaim sweep (T-Q9) returns expired-lock items to the queue.

This is the **reference implementation** of the broker contract. The HTTP contract pinned here is **language-agnostic** — the future Redis-backed broker (T7) is implemented in Go and reuses these HTTP fixtures via black-box conformance tests, not shared type imports. Author the HTTP request/response shapes as a JSON fixture set (e.g. `runtime/broker-protocol/fixtures/`) checked into the repo; both T3 (in-process TS) and T7 (separate Go service) must pass them identically.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Implement in-flight registry as `Map<handle, { nonce, kind, subkind?, task_id, registered_at }>`
- [ ] Implement completion queue with peek-and-lock + per-item `locked_until`
- [ ] Implement `register(handle, nonce, metadata)`
- [ ] Implement `listCompleted({ max, lockMs })` — atomic peek + mark locked
- [ ] Implement `ack(handle)` — invalidate nonce, remove registry entry
- [ ] Implement `nack(handle)` — return locked item to queue immediately
- [ ] Bind `POST /callback` HTTP route at orchestrator startup
- [ ] Generate per-orchestrator port (ephemeral by default; write to runtime file per T-Q10)
- [ ] Validate nonce in callback handler; 401 on invalid
- [ ] Implement reclaim sweep on visibility-timeout expiry (cadence per T-Q9)
- [ ] Write hermetic TS test suite for in-process behaviour
- [ ] Author the **broker protocol JSON fixtures** (`runtime/broker-protocol/fixtures/`) — language-agnostic HTTP request/response shapes. Run them against this adapter end-to-end. T7 (Go) reuses them.

---

## T4 — Runner wrapper script (D6c)

### Description
Implement the platform-owned wrapper script (`runner.js`, per T-Q8) that runs as the entrypoint of every spawned executor. It exec's the bundled executor binary, reads `RESULT_PATH` on exit, and POSTs `{ handle, nonce, result }` to `$CALLBACK_URL` with bounded exponential-backoff retries on transport errors. Same script across both `local-subprocess` and `local-docker`.

Keep the wrapper's runtime to Node stdlib only — no external dependencies — so the docker image surface is unchanged.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Read env: `BRIEFING_PATH`, `RESULT_PATH`, `CALLBACK_URL`, `HANDLE`, `NONCE`
- [ ] Spawn the executor binary as a child; await exit
- [ ] On normal exit: read `RESULT_PATH`, build callback body
- [ ] On non-zero exit: build a `failed` callback body with exit code + tail of stderr
- [ ] POST to `$CALLBACK_URL` with bounded retries (exponential backoff)
- [ ] Use only Node stdlib (`http`, `child_process`, `fs`); no `node_modules`
- [ ] Unit tests with a fake HTTP receiver; cover happy path, non-zero exit, transport retry

---

## T5 — `SubProcessAdapter` async submit/reap with broker integration

### Description
Refactor `SubProcessAdapter` from the Wave-2 blocking shape to the async runner-callback shape. `submit` registers the handle with the broker, then spawns the runner wrapper (T4) as a child with the env contract from T-Q10. The adapter records `(handle, pid, started_at, nonce)` in its **runner-supervision map** for the wrapper-crash safety net only — not as in-flight state (the broker owns that).

`child.on('exit')` is the safety net: if the child exits without a callback reaching the broker within a grace window, the adapter POSTs a synthetic `failed` completion to the broker on the runner's behalf.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Refactor `submit` — call `broker.register` first, then `child_process.spawn` runner wrapper
- [ ] Pass env vars: `BRIEFING_PATH`, `RESULT_PATH`, `CALLBACK_URL`, `HANDLE`, `NONCE`
- [ ] Implement runner-supervision map keyed by handle
- [ ] Implement `child.on('exit')` wrapper-crash safety net (synthetic `failed` POST)
- [ ] `readResult` is a no-op for this profile (result rides in the callback)
- [ ] `ack` is delegated to the broker; adapter cleans up the temp result file
- [ ] Integration tests: happy path, wrapper crash before POST, late callback, broker-reject (replay)

---

## T6 — Refactor orchestrator concerns + shared reap loop

### Description
Replace today's blocking `spawn + await exit` flow in the claim and review-fix concerns with the async pattern: register handle → submit → return. Add a shared reap loop that calls `broker.listCompleted({ lockMs })`, routes by `handle.kind`, dispatches side-effects via the existing claim/review-fix dispatchers, and acks. Persist handles to the task YAML at submit time per the technical-design's reconciliation pattern.

End of task: orchestrator's cycle no longer waits for any single executor to finish. Pool size is decoupled from concurrent task count.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Refactor claim concern: `broker.register` + `executor.submit`; no await
- [ ] Refactor review-fix concern (subkind=rebase, subkind=respond) with the same shape
- [ ] Implement shared reap loop in `agent-loop.ts` (Shape A — sequential cycle)
- [ ] Route `listCompleted` results by `handle.kind` to the right dispatcher
- [ ] Persist handles to task YAML at submit time
- [ ] Update existing claim/review-fix tests to the new flow
- [ ] End-to-end test: claim → submit → callback → reap → dispatch → done

---

## T7 — Redis-backed broker service (Go) + container

### Description
Implement the broker service as a **standalone Go binary** backed by Redis, conforming to the language-agnostic HTTP contract pinned by T3. This is the workspace's first Go service, in line with the language policy at `docs/language-policy.md` ("new standalone services in Go; existing components and orchestrator core stay in TypeScript").

Use `net/http` for the receiver, `go-redis` for the Redis client, and Redis Streams + consumer groups for peek-and-lock; enforce visibility timeout via `XPENDING` + `XCLAIM` reclaim sweep. Single static binary; small container image.

The orchestrator-side adapter for `local-docker` (in TypeScript) talks to this service over HTTP — language boundary at the network, no in-process interop. Behavioural parity with `InMemoryBrokerAdapter` (T3) is the acceptance bar; the parity tests are **black-box HTTP fixtures** (request/response JSON shapes), not shared type imports.

### Required skills
- go-best-practices

### Subtasks
- [ ] Lay out Go module structure (`cmd/broker/main.go`, internal packages)
- [ ] Implement `POST /callback` route validating the per-handle nonce
- [ ] Implement `register` / `listCompleted` (peek+lock) / `ack` / `nack` HTTP routes (broker's orchestrator-facing surface)
- [ ] Wire `go-redis` client; use Redis Streams + consumer groups for peek-and-lock
- [ ] Implement `XPENDING` + `XCLAIM` visibility-timeout reclaim sweep (cadence per T-Q9)
- [ ] Document the AOF/RDB Redis defaults; flag that production HA is BYO
- [ ] Multi-stage Dockerfile producing a small static-binary container image
- [ ] Add Go to CI (toolchain, `go test`, build)
- [ ] Author the JSON-fixture parity test suite (HTTP request/response shapes); both T3 (in-process) and T7 (Go service) must pass it identically

---

## T8 — `DockerRunAdapter`

### Description
Implement the Docker-spawning executor adapter for the `local-docker` profile. `submit` registers the handle with the broker, then `docker run -d` of the Claude executor image with the runner wrapper (T4) mounted in and set as the entrypoint. Container joins the shared bridge (`agents-net`) so it can resolve `broker:7000` via service-name DNS. The adapter holds a `docker wait` on each spawned container as the wrapper-crash safety net.

`ack` removes the container and unlinks the result file. A periodic orphan sweep handles containers whose ack never fires (rare-edge case where the broker was lost mid-flight).

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Implement `submit` — `broker.register` + `docker run -d` with mounted wrapper, env vars, label
- [ ] Construct `CALLBACK_URL=http://broker:7000/callback`
- [ ] Set `--restart=no`; do not use `--rm`
- [ ] Apply `platform.handle=<handle>` label
- [ ] Hold `docker wait <container_id>` as the wrapper-crash safety net (sythetic `failed` POST)
- [ ] `ack` runs `docker rm <container_id>` and unlinks the result file
- [ ] Implement periodic orphan sweep (`docker ps -a -f label=platform.handle=*` against in-flight broker entries)
- [ ] Integration tests under `local-docker`: happy path, wrapper crash, broker-reject, orphan cleanup

---

## T9 — docker-compose template + bridge network

### Description
Wire the M:N topology in docker-compose: one bridge network (`agents-net`), one Redis container, one broker service container, N agent containers (each with the Docker socket mounted so they can `docker run` executor containers attached to the same bridge). Validate that runners spawned by any agent reach the broker by service-name DNS.

End of task: M:N is functional locally — multiple agents spawn per-task executor containers; runners POST to the shared broker; any orchestrator drains.

### Required skills
- backend-engineer

### Subtasks
- [ ] Define `agents-net` bridge network in `docker-compose.yml`
- [ ] Add `redis` service
- [ ] Add `broker` service (image from T7), `depends_on: [redis]`
- [ ] Define `agent-N` services: image, Docker socket mount, broker URL env, joined to `agents-net`
- [ ] Configure `docker run` invocations from `DockerRunAdapter` to `--network agents-net`
- [ ] Verify network reachability: agent → broker, executor → broker (via service-name DNS)
- [ ] M:N test: 3 agents, 5 concurrent tasks, all complete; verify dispatch is opportunistic

---

## T10 — Portability spec doc + fake-orchestrator harness + CLAUDE.md updates + operator setup

### Description
Close out the feature with documentation. Author `runtime/portability-spec.md` documenting every port (including `CompletionBrokerPort`) and adapter, with the per-profile mechanism contract derived from "How `submit` works per profile" in the technical design. Update the executor team's `fake-orchestrator` harness to use the new `ExecutorPort` + `CompletionBrokerPort` contracts so executor authors test against the interface the platform actually uses. Update `CLAUDE.md` references that assume the bundled-image model.

This task also lands the **language policy** for the workspace: a short, durable note that orchestrator core, runner wrapper, and existing adapters stay in TypeScript while new standalone services (starting with T7's broker) are written in Go. The policy lives at `docs/language-policy.md` (workspace-level) and is referenced from this feature's portability spec.

Finally, this task separates the operator quickstart into profile-specific guides and cleans up stale content in the operator docs that was left from the development rollout.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Author `runtime/portability-spec.md` covering every port + adapter + profile
- [ ] Document the `runner.js` env contract and POST payload shape
- [ ] Document the per-profile `submit` mechanism (subprocess, docker, future K8s, future pull)
- [ ] Document the **broker protocol JSON fixtures** as the language-agnostic source of truth
- [ ] Update `fake-orchestrator` harness to use new contracts
- [ ] Update `CLAUDE.md` sections that assume the bundled-image model
- [ ] Reference `docs/language-policy.md` from `runtime/portability-spec.md`
- [ ] Add a "How to add a new profile" section to `runtime/portability-spec.md`
- [ ] Create `runtime/orchestrator/templates/QUICKSTART-local-docker.md` — dedicated M:N setup guide
- [ ] Update `runtime/orchestrator/templates/QUICKSTART.md` — add "Which profile?" section and link to local-docker guide
- [ ] Clean up `runtime/orchestrator/docs/OPERATOR-GUIDE.md` — remove stale "Deleted legacy paths" and "Smoke-gate outcome" sections; update Day-1 note to reflect that `local-docker` is now available
