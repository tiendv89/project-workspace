# Tasks — runtime-runcycle-decomposition

## T1 — Split runOneCycle into named poll-step sub-functions

**Repo:** workflow  
**Branch:** feature/runtime-runcycle-decomposition-T1  
**Actor:** agent

### Description

`runOneCycle` in `runtime/orchestrator/src/main.ts` (lines 356–978) is a ~620-line monolith. Extract named sub-functions that each own one step of the poll cycle so GitNexus can trace call edges into `handleMergedPrs`, `claimRebase`, and related T6 functions.

### Subtasks

- [ ] Read `main.ts:356–978` in full to identify step boundaries
- [ ] Define a local `ctx` object / interface capturing shared local variables
- [ ] Extract `stateInvariantBlock(ctx)` → `runStateInvariantCheck`
- [ ] Extract `featureReviewBlock(ctx)` → `runFeatureReviewCycle`
- [ ] Extract `claimBlock(ctx)` → ready-task scan + claim + executor spawn
- [ ] Extract `mergedPrsBlock(ctx)` → `await handleMergedPrs(...)`
- [ ] Extract `dispatchBlock(ctx)` → 5a (mergedPrsBlock + rebase dispatch) + 5b (reviewer dispatch)
- [ ] Verify `runOneCycle` is now a thin sequencer calling the above in order
- [ ] Run `npm test` in `runtime/orchestrator` — all tests must pass
- [ ] Open PR

### Required skills

- go-best-practices
- typescript-best-practices
