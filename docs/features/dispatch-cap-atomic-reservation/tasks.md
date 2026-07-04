# Tasks — `dispatch-cap-atomic-reservation`

## T1 — Atomic `dispatch:active` reservation in the dispatcher

**Repo**: `workflow` (`agent-workflow`)

### Description
Replace the `GET /registry-size`-based cap check in
`DispatchStreamConsumer._processEntry()` with an atomic Lua-script
reservation against a new `dispatch:active` Redis Sorted Set, per
`technical-design.md`. Wire release into `ContainerReaper` (primary path,
on confirmed container removal) and into every non-spawn exit path in
`_processEntry` that follows a reservation (lock-lost, duplicate-container,
DLQ, credential error, spawn error).

### Subtasks
- [ ] Add `_tryReserveSlot(handle)` / `_releaseSlot(handle)` to
      `DispatchStreamConsumer`, backed by the `dispatch:active` sorted-set
      Lua script.
- [ ] Replace the `_getRegistrySize()`/`inFlight >= maxConcurrent` check in
      `_processEntry` with `_tryReserveSlot`.
- [ ] Release the reservation on every post-reservation exit path that does
      not end in `dispatch_spawn_ok` (lock-lost, duplicate-container, DLQ,
      credential error, spawn error).
- [ ] Add a `releaseSlot` dependency to `ContainerReaperOpts`; call it right
      after a successful `removeContainer()` in `sweepOnce()`.
- [ ] Wire the new dependency wherever the consumer and reaper are
      instantiated together (share the existing Redis client).
- [ ] Add `activeSlotTtlMs` dispatcher option (default 24h) for the
      safety-net expiry score.
- [ ] Tests: atomic reservation rejects the (maxConcurrent+1)th concurrent
      reserve; reservation is released on lock-lost / duplicate-container /
      DLQ / credential-error / spawn-error; reaper releases on removal;
      registering N sibling tasks up front (simulating the auto-ready
      cascade) no longer blocks spawning up to `maxConcurrent`.

### Test plan
- [ ] `runtime/dispatcher`: full suite green, including new reservation
      tests.
- [ ] `npx tsc --noEmit` clean.
- [ ] Manual: redeploy and confirm no cap overshoot / no self-deadlock under
      a burst of sibling-task submissions.

### Required skills
- backend-engineer
- typescript-best-practices
