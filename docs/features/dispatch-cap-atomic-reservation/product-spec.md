# Product Specification

## Feature
- Feature ID: `dispatch-cap-atomic-reservation`
- Title: Atomic concurrency-cap reservation for the dispatcher

## Problem

The dispatcher's `maxConcurrent` cap is enforced by reading `GET /registry-size`
from the broker (a snapshot of all registered-but-not-yet-acked handles) and
comparing it against `maxConcurrent` before spawning a container. This check
is a plain read-then-act with no atomicity, and `registry-size` counts *all*
in-flight work (from orchestrator `submit()` time through task completion),
not just currently-running containers.

Observed in production on 2026-07-04 (`agent-031352` VM, `charting-layer`
feature, tasks T3–T6):

1. **Self-inflicted stall.** Four sibling tasks became `ready` together (via
   the auto-ready cascade) and were all registered with the broker up front,
   before any of them could spawn. `registry-size` immediately read 4 against
   a cap of 3. Since none of the four could spawn, none could complete, so
   none could `ack()` — the registry count never dropped on its own. All four
   were stuck in a `dispatch_cap_exceeded` retry loop for ~13 minutes.
2. **Cap overshoot burst.** Once the count incidentally dropped (an unrelated
   registration elsewhere expired/acked), the four entries were reclaimed by
   `XAUTOCLAIM` one at a time, roughly 10–12s apart — four separate `run()`
   loop iterations, each issuing its own independent `GET /registry-size`
   call with no coordination between them. All four checks passed and all
   four containers spawned, exceeding `maxConcurrent=3`.

The dispatcher's own code comment already documents this as a known gap:
> "The cap remains advisory across the dispatcher pool ... A hard global
> limit would need an atomic reservation (e.g. a Redis counter), deferred
> until prod needs it."

This incident is that "prod needs it" moment.

## Goals
- Make the concurrency-cap check-and-admit operation atomic, closing the
  check-then-act race that allowed 4 containers to spawn against a cap of 3.
- Decouple the cap from total in-flight *registered* work and scope it to
  currently *spawned-and-not-yet-reaped* containers, so a batch of sibling
  tasks becoming `ready` together no longer self-deadlocks dispatch.
- Preserve existing behavior for stale-entry handling, DLQ routing, and the
  per-handle spawn lock (TOCTOU protection for a single handle) — this
  feature only changes how the *cross-handle* concurrency budget is tracked.

## Non-goals
- Enforcing a hard cap across multiple dispatcher *processes* sharing one
  Redis (out of scope — this deployment runs a single dispatcher instance;
  multi-dispatcher coordination can reuse the same atomic primitive later
  but is not required now).
- Changing the broker's `registry-size` semantics (`registered, un-acked`)
  — that endpoint remains correct for its existing purpose (reaper checks,
  callback validation) and is left untouched.
