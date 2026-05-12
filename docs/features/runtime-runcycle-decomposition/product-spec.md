# Product Spec — runtime-runcycle-decomposition

## Overview

`runOneCycle` in `runtime/orchestrator/src/main.ts` is a ~620-line monolith (lines 356–978). Because it is so large, GitNexus cannot resolve call edges from it into the separate poll/dispatch modules — `handleMergedPrs`, `claimRebase`, and similar T6-shipped functions show zero incoming edges in the code graph.

This feature extracts named sub-functions from `runOneCycle` so the poll cycle is a thin sequencer of well-named calls, making the call graph traceable by GitNexus and readable by humans.

## Goal

- Split `runOneCycle` into 4–6 named sub-functions that each own one step of the poll cycle.
- No behaviour changes. No new logic. Pure extraction refactor.
- GitNexus must be able to trace incoming edges to `handleMergedPrs` and `claimRebase` after the change.

## Proposed extraction boundaries

| Extracted function | Responsibility |
|---|---|
| `dispatchBlock` | Step 5a: conflict rebase dispatch; step 5b: reviewer dispatch |
| `claimBlock` | Scan ready tasks, claim + spawn executor |
| `mergedPrsBlock` | Wrap `handleMergedPrs` call (step 5a sub-step) |
| `stateInvariantBlock` | `runStateInvariantCheck` |
| `featureReviewBlock` | `runFeatureReviewCycle` |

`runOneCycle` becomes a sequencer: calls the above in the correct order, passing shared context.

## Out of scope

- No logic changes
- No new tests (existing test suite verifies behaviour)
- No other files beyond `main.ts`

## Success criteria

- All existing tests pass (`npm test` in `runtime/orchestrator`)
- GitNexus context call on `handleMergedPrs` shows at least one incoming edge after re-indexing
- PR diff is pure moves/renames — no net-new logic
