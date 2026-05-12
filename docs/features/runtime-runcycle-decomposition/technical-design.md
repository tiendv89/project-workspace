# Technical Design — runtime-runcycle-decomposition

## 1. Summary

Extract named sub-functions from the `runOneCycle` monolith in `runtime/orchestrator/src/main.ts`. No logic changes — pure structural refactor.

## 2. File scope

| File | Change |
|---|---|
| `runtime/orchestrator/src/main.ts` | Extract sub-functions; `runOneCycle` becomes a thin sequencer |

No other files change.

## 3. Extraction plan

Read `main.ts:356–978` and identify the natural step boundaries matching the T6 dispatch model:

```
runOneCycle(ctx)
  ├── stateInvariantBlock(ctx)      // runStateInvariantCheck
  ├── featureReviewBlock(ctx)       // runFeatureReviewCycle
  ├── claimBlock(ctx)               // scan ready tasks → claim → spawn executor
  └── dispatchBlock(ctx)            // 5a: mergedPrsBlock + conflict rebase dispatch
                                    // 5b: reviewer dispatch (only if 5a idle)
        ├── mergedPrsBlock(ctx)     // await handleMergedPrs(...)
        └── (rebase / reviewer)
```

Each extracted function receives a shared `ctx` object containing all values that `runOneCycle` currently holds as local variables (repo coords, tokens, emit, etc.). The `ctx` type is inlined or declared as a local interface in `main.ts` — no new exported types.

## 4. Constraints

- All extracted functions are **local to `main.ts`** (not exported) — they are implementation detail, not API surface.
- `runOneCycle`'s signature and return type do not change.
- Extraction must preserve exact ordering: stateInvariant → featureReview → claim → dispatch (5a before 5b).
- No early-return logic changes — existing `outcome` checks stay as-is, just moved inside the relevant sub-function.

## 5. Test strategy

Run existing suite only:

```bash
cd runtime/orchestrator && npm test
```

No new tests. If any test fails, the extraction introduced a bug — fix before opening PR.

## 6. Repository impact

| Repo | Files | Reason |
|---|---|---|
| workflow | `runtime/orchestrator/src/main.ts` | Only file in scope |
