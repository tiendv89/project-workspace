# Handoff — agent-runtime-redesign

**Feature:** Agent runtime redesign — per-handle executor isolation, claim-based rebase, dispatch-block restructuring
**Completed:** 2026-05-12
**All tasks:** T2–T6 (5/5) done

---

## What was built

The orchestrator's runtime topology and PR-handling pipeline were rewritten end-to-end. Executors no longer share a single workspace directory; each invocation gets its own `exec-{handle}` workdir with a per-handle clone of the impl + mgmt repos. The synchronous in-process rebase / merge-done helpers were replaced by an async `kind:"rebase"` executor dispatch (with a first-push-wins `claimRebase`) and a properly-awaited `handleMergedPrs`. The dispatch block was reorganised so PR-poll work runs before reviewer dispatch, eliminating a class of cross-task races. `status.yaml` gained `workspace_feature_pr_url` to separate the lifecycle PR from the handoff PR, and the Handoff Trigger and Feature Done Watcher were rebuilt around the new field semantics.

### Tasks and PRs

| Task | Title | PR |
|---|---|---|
| T2 | Lifecycle Manager: record `workspace_feature_pr_url` | [#135](https://github.com/tiendv89/agent-workflow/pull/135) |
| T3 | Handoff Trigger redesign | [#136](https://github.com/tiendv89/agent-workflow/pull/136) |
| T4 | Feature Done Watcher redesign | [#137](https://github.com/tiendv89/agent-workflow/pull/137) |
| T5 | ABI + executor startup: `EXECUTOR_WORKDIR` two-phase startup | (landed alongside T2 — #135) |
| T6 | Orchestrator dispatch + adapters | [#138](https://github.com/tiendv89/agent-workflow/pull/138) |

All PRs merged into `tiendv89/agent-workflow:main`.

---

## Architectural changes

### Per-handle executor isolation (T5 + T6)

Old: a single `workspacesDir` was bind-mounted into every container, so concurrent executors shared a working tree and could clobber each other's `git rebase` state. The runtime relied on a `skipImplRepoPull` guard to suppress `syncRepo()` while an executor was in flight — fragile and subprocess-only.

New: each executor invocation gets `${workspacesDir}/exec-{handle}` (host path), mounted into the container at `/workspace`. The executor's two-phase startup:
- **Phase 1:** clone `MGMT_REPO_URL` to `${EXECUTOR_WORKDIR}/mgmt` (read-only on `main`); sets `WORKSPACE_ROOT` from this path so `copyWorkspaceClaude` / `setupGlobalSkills` find their inputs.
- **Phase 2:** materialise impl repo at `${EXECUTOR_WORKDIR}/impl` and check out the task branch.

`ack()` removes the per-handle directory after the broker finishes draining the result. The `skipImplRepoPull` / `execInFlight` guard is gone — pull-workspaces is safe to run every cycle.

### ABI changes (T5)

Added to `ExecutorInput` / runner env:
- `HANDLE` — executor invocation UUID (already used by docker; now also set for subprocess)
- `EXECUTOR_WORKDIR` — base directory the executor manages
- `MGMT_REPO_URL` — management repo git URL (executor clones read-only)

Removed:
- `TASK_REPO_PATH` — executor derives `${EXECUTOR_WORKDIR}/impl`
- `WORKSPACE_ROOT` from orchestrator env — executor derives `${EXECUTOR_WORKDIR}/mgmt`

`HandleKind` gained `"rebase"`. The old `"review-fix"` kind and its reap-loop handler are kept as inert dead code per design § 4.6.

### Rebase as an executor (T6)

Old: `handleMergeConflicts` ran inline in the PR poll, invoking Claude synchronously in the orchestrator process against a host path resolved via `resolveRepoLocalPath`. This couldn't survive executor isolation.

New: when `checkInReviewPrs` reports `mergeable: false`, the orchestrator:
1. **`claimRebase`** writes a `rebase_started` log entry + `conflict_state: resolving` to the task YAML on the mgmt repo task branch and pushes. If the push is rejected (another agent claimed first), the dispatch is skipped — first-push-wins.
2. Dispatches a `kind:"rebase"` executor via the same adapter as task executors, with a minimal briefing telling it to rebase the branch and resolve conflicts.
3. On result: `terminal_status: "in_review"` → reap loop writes `conflict_state: resolved` to the task YAML; `terminal_status: "blocked"` → `status: blocked, blocked_reason: pr_conflict` via `mutateTaskYaml`.

`rebaseInFlight: Set<string>` (keyed `featureId:taskId`) provides docker-mode per-task dedup; the in-process `claimRebase` provides cross-orchestrator dedup. Both are cleared on ack and on nack.

### Dispatch block restructuring (T6)

Per § 4.4 of the design, the PR poll moved **into** `dispatchBlock`, before `findReviewableTasks`:

```
dispatchBlock {
  3. Eligible-task dispatch
  4. Fix-agent dispatch
  5a. checkInReviewPrs
        mergeable:false -> claimRebase + dispatch kind:"rebase"
        merged:true     -> await handleMergedPrs (async orch. code)
  5b. findReviewableTasks -> dispatchReviewer
        (only runs when 5a found nothing — outcome !== "ran_task")
}
```

This closes a race where a reviewer and rebase executor could be co-dispatched in the same cycle for the same `mergeable: false` task in docker mode (subprocess mode was already protected by `skipPrPoll`).

### `handleMergedPrs` is awaited inline in step 5a

The initial T6 plan was fire-and-forget. Final commit `8da13f9` reverted to `await` (with try/catch surfacing errors as `handle_merged_prs_error`) because the next cycle's `syncRepo` could race with the merge-done cascade push, hiding newly auto-readied tasks for an extra cycle. Trade-off: dispatch loop blocks for ~1–2 s on cycles that detect a merged PR. § 4.4, § 4.0 step 9, and § 4.9 of the technical design were updated alongside this handoff to match the shipped semantics.

### `status.yaml` schema

- `workspace_feature_pr_url` (NEW, T2) — draft PR `feature/{id}` → `main`. Set by the Lifecycle Manager on first creation.
- `handoff_pr_url` (repurposed, T3) — PR `handoff/feature-{id}` → `feature/{id}`. Set by the Handoff Trigger.
- `impl_feature_prs` (NEW, T3) — list of `{repo, url, status}` for each impl repo PR opened by the Handoff Trigger.

Migration: features in `in_handoff` with the old `handoff_pr_url` semantics fall back gracefully — Feature Done Watcher treats `handoff_pr_url` as `workspace_feature_pr_url` when the new field is absent.

### Feature Done Watcher (T4)

Now checks both `handoff_pr_url` and every entry in `impl_feature_prs`. When all are merged: checks out `feature/{id}`, writes `feature_status: done, current_stage: done` to `status.yaml`, commits + pushes, and auto-merges the workspace feature PR via the GitHub REST API.

### Handoff Trigger (T3)

Replaced inline promote-or-create with a four-step sequence:
- **5a.** create `handoff/feature-{id}` from `feature/{id}`
- **5b.** commit `handoff.md` and push
- **5c.** open `handoff/feature-{id}` → `feature/{id}` (mgmt repo, non-draft)
- **5d.** open `feature/{id}` → `<base_branch>` PR in each impl repo referenced by the feature's tasks

---

## Operational notes

### Profiles

Both `local-subprocess` and `local-docker` runtime profiles work with the new design. Subprocess mode benefits from `skipPrPoll` as an additional guard; docker mode relies on `claimRebase` + `rebaseInFlight` for dedup.

### Removed config

- `pr_poll_interval_seconds` — `checkInReviewPrs` runs every poll cycle now; `idle_sleep_seconds` provides natural rate limiting (well within GitHub's GraphQL budget for any realistic feature load).

### Tests

- Bootstrap tests rewritten to assert `existsSync(implPath) === false` and `process.env[implEnvVar] === undefined` after T6 (impl repos are no longer cloned by bootstrap — executors handle their own).
- `kind:"rebase"` reap-loop handler covered by reap-loop unit tests; `claimRebase` push-rejection path tested via `auto-rebase.test.ts`.
- Lifecycle, Handoff Trigger, and Feature Done Watcher have updated unit + integration tests for the new `status.yaml` schema.
- Full vitest suite green on every merged PR.

---

## Known follow-ups

| Item | Note |
|---|---|
| ~~`WorkspacePrRecovery` dead code~~ | Resolved in [#139](https://github.com/tiendv89/agent-workflow/pull/139) — interface, `handleWorkspacePrRecoveries`, and tests removed (–322 lines). |
| `rebaseInFlight` Set is in-memory | An orchestrator restart while a rebase is mid-flight requires `claimRebase`'s `conflict_state: "resolving"` flag (committed to origin) to act as the persistent dedup. Working as designed, but worth documenting. |

---

## File map

```
runtime/orchestrator/src/
  main.ts                                  # dispatch block restructured (5a inside, before 5b)
  bootstrap/bootstrap.ts                   # impl repo cloning + skipImplRepoPull removed
  poll/check-in-review-prs.ts              # WorkspacePrRecovery scanning removed; in_review_poll_warn on catches
  poll/reap-loop.ts                        # kind:"rebase" handler; rebaseInFlight delete on ack/nack
  poll/handle-merged-prs.ts                # awaited inline (try/catch wrap)
  poll/handle-feature-done.ts              # workspace_feature_pr_url auto-merge
  pr-response/auto-rebase.ts               # claimRebase() exported; handleMergeConflicts now dead code
  lifecycle-manager/lifecycle-manager.ts   # workspace_feature_pr_url write
  handoff-trigger/handoff-trigger.ts       # four-step handoff PR flow
  adapters/executor/subprocess.ts          # HANDLE/EXECUTOR_WORKDIR/MGMT_REPO_URL env; ack() rmSync
  adapters/executor/docker-run.ts          # per-handle volume mount; ack() host-path cleanup

runtime/abi/src/types.ts                   # HandleKind += "rebase"; ABI field changes

runtime/executors/claude/src/index.ts      # two-phase startup (mgmt then impl)
```
