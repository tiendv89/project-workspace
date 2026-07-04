# Technical Design

## Feature
- Feature ID: `dispatch-cap-atomic-reservation`
- Title: Atomic concurrency-cap reservation for the dispatcher

## Current State

`DispatchStreamConsumer` (`runtime/dispatcher/src/consumer.ts`) enforces
`maxConcurrent` in `_processEntry()`:

```ts
const inFlight = registrySize ?? (await this._getRegistrySize());
if (inFlight >= this.maxConcurrent) { /* leave pending, return false */ }
```

`_getRegistrySize()` is an HTTP `GET /registry-size` call to the broker, which
returns the count of `broker:reg:*` keys in Redis — handles that are
registered (at orchestrator `submit()` time, before enqueue) and not yet
`ack()`'d (at task completion). This is "total in-flight work," not
"containers currently running."

`run()`'s batch loop tries to compensate for read-then-act staleness within a
single batch:

```ts
const registrySize = await this._getRegistrySize();
let admitted = 0;
for (const e of entries) {
  const consumedSlot = await this._processEntry(e, registrySize + admitted);
  if (consumedSlot) admitted++;
}
```

This only protects entries processed in the *same* batch. Entries reclaimed
by `XAUTOCLAIM` one at a time across separate `run()` iterations each get an
independent, uncoordinated `GET /registry-size` snapshot — no atomicity
across iterations. The code's own comment acknowledges this:

> "The cap remains advisory across the dispatcher pool ... A hard global
> limit would need an atomic reservation (e.g. a Redis counter), deferred
> until prod needs it."

## Constraints
- Must not change `broker:reg:*` semantics or the `/registry-size` endpoint
  — the reaper and callback-validation paths depend on its current meaning
  ("registered, un-acked") and are out of scope.
- Must not require a second Redis instance or a new service — the dispatcher
  already holds a `RedisClientType` connected to the same Redis the broker
  uses.
- Must survive a dispatcher process restart without manual reconciliation
  (state lives in Redis, not dispatcher memory — same pattern as the
  existing spawn-lock and DLQ spawn-attempt counters).
- Must self-heal if a release is ever missed (dispatcher crash between
  reserving a slot and the corresponding release) — no permanent leak.

## Options Considered

### Option A — Keep `registry-size`, add a mutex around the whole check-and-spawn sequence
Wrap `_getRegistrySize()` + spawn in a Redis-based distributed lock so only
one `_processEntry` call can be "in the cap-check critical section" at a time.
- Pros: minimal new state, no new Redis key.
- Cons: doesn't fix the root problem — `registry-size` still counts
  registered-but-not-yet-spawned work, so the self-deadlock (Goal 1 in the
  product spec) is untouched. A lock only serializes the race, it doesn't
  change what's being counted. Also serializes all dispatch globally,
  adding latency for no benefit once the count is wrong for the *other*
  reason.

### Option B — Atomic reservation Set scoped to actually-spawned containers
Add a Redis Sorted Set `dispatch:active` (member = handle, score = a
generous safety-net expiry). Reserve via a single Lua script that purges
expired members, checks cardinality against `maxConcurrent`, and adds the
handle — all atomically. Release when the reaper confirms the container is
terminated-and-unregistered, or immediately if the spawn never actually
started (lock lost, duplicate, DLQ, credential error, spawn error).
- Pros: fixes both symptoms — (1) cap now tracks *actually running*
  containers, so registering four sibling tasks up front no longer
  self-deadlocks dispatch; (2) the Lua script closes the check-then-act
  race regardless of how many separate `run()` iterations are involved,
  since cardinality-check-and-add is one atomic op on the Redis server.
- Cons: one new Redis key to reason about; release must be wired into every
  exit path that follows a successful reservation.

## Chosen Design

**Option B.** It addresses the actual root cause in the product spec (cap
should track running containers, not total in-flight work) and closes the
race atomically, matching the same Lua-script pattern already used for the
slot-key supersede fix (PR #281) and the existing spawn-lock (`SET NX PX`).

### `dispatch:active` — Sorted Set
- Member: `job.handle`
- Score: `now_ms + activeSlotTtlMs` (a generous backstop ceiling, default
  24h — mirrors `DefaultRegistrationTTL` in the broker). This is a
  last-resort safety net, not the primary release mechanism; the reaper is
  expected to release normally, long before this TTL is ever reached.

### `_tryReserveSlot(handle)` — Lua script, replaces the `_getRegistrySize()` cap check
```lua
-- KEYS[1] = dispatch:active
-- ARGV[1] = handle
-- ARGV[2] = now_ms
-- ARGV[3] = maxConcurrent
-- ARGV[4] = expiry_ms (now_ms + activeSlotTtlMs)
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[2])
local count = redis.call('ZCARD', KEYS[1])
if count >= tonumber(ARGV[3]) then
  return 0
end
redis.call('ZADD', KEYS[1], ARGV[4], ARGV[1])
return 1
```
Called where the old `inFlight >= this.maxConcurrent` check lived in
`_processEntry`. A `0` result is treated exactly like today's
`dispatch_cap_exceeded` (leave entry pending, `XAUTOCLAIM` redelivers).

### `_releaseSlot(handle)` — `ZREM dispatch:active <handle>`
Called from:
1. **`ContainerReaper.sweepOnce()`** — immediately after a successful
   `removeContainer()` (the container is terminated and unregistered, so its
   slot is definitively free). This is the primary release path.
2. **`_processEntry`**, on every post-reservation exit that does *not* reach
   a successful `dispatch_spawn_ok`: lock-lost, duplicate-container
   backstop, DLQ (`attempt > maxDeliveries`), credential error, and spawn
   error. None of these leave a container running, so nothing will ever
   reap them — the slot must be released inline instead.

The reservation is deliberately made *before* the per-handle spawn lock
(same position as today's cap check) so a capacity wait still leaves the
entry untouched for cheap redelivery. Every code path between reservation
and the terminal `dispatch_spawn_ok` now releases on its way out.

## Dependency Analysis
- `ContainerReaper` gains a new required dependency: a `releaseSlot(handle)`
  callback (or direct Redis access) — wired from `main.ts`/whatever
  instantiates both the consumer and the reaper today, since they already
  share one Redis client.
- No changes to `runtime/broker` (Go) or `runtime/orchestrator` — this is
  fully contained in `runtime/dispatcher`.
- No schema/migration impact (no relational DB involved).

## Parallelization / Blocking Analysis
Single task, single repo (`workflow` / `agent-workflow`), no dependencies.
Can proceed immediately.
