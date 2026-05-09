# Task Breakdown — Autonomous Feature Reviewer

**Feature status:** `in_tdd` | **Stage:** `tasks` (awaiting approval) | Machine state lives in `tasks/T<n>.yaml`

---

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Reviewer Identity injection | — |
| T2 | 1 | Lifecycle Manager wiring + Handoff Trigger extension | — |
| T5 | 1 | Fix eligibility/match.ts — feature-branch task dispatch | — |
| T6 | 1 | Fix handle-merged-prs.ts — sibling status map reads feature branch first | — |
| T3 | 2 | Feature Done Watcher | T2, T5, T6 |
| T4 | 3 | Feature Reviewer Daemon | T3 |

---

## T1 — Reviewer Identity injection

### Description

The reviewer executor currently runs with the same `GITHUB_TOKEN` as the impl bot. GitHub returns HTTP 422 when a bot tries to post a formal review (`APPROVE` / `REQUEST_CHANGES`) on a PR it opened — the two-call workaround in `dispatch-review-result.ts` swallows the error but loses the structured review event.

This task wires a dedicated reviewer identity through the orchestrator so the reviewer subprocess runs as a different GitHub account:

1. **`dispatch-reviewer.ts`** — add `reviewerGithubToken?`, `reviewerGitAuthorName?`, `reviewerGitAuthorEmail?` to `DispatchReviewerOpts`. In `extraEnv`, override `GITHUB_TOKEN`, `GIT_AUTHOR_EMAIL`, `GIT_AUTHOR_NAME` with the reviewer values when they are set; fall back to the impl values when absent.
2. **`main.ts`** — read `REVIEWER_GITHUB_TOKEN`, `REVIEWER_GIT_AUTHOR_NAME`, `REVIEWER_GIT_AUTHOR_EMAIL` from `process.env` near the existing `githubToken` block; pass to `dispatchReviewer()`.
3. **`technical_skills/review-pr/SKILL.md`** — update the skill to prefer `REVIEWER_GITHUB_TOKEN` over `GITHUB_TOKEN` when posting both the issue comment and the GitHub review event. Retain `reviewer_self_review_skipped` as a safety-net fallback for when the env var is absent.

When all three are in place, the reviewer account never opens PRs, so self-review HTTP 422 cannot occur in normal operation.

### Required skills

- `typescript-best-practices`
- `review-pr`

### Subtasks

- [ ] Read `runtime/orchestrator/src/pr-response/dispatch-reviewer.ts` — confirm current `extraEnv` shape and `DispatchReviewerOpts` interface
- [ ] Add `reviewerGithubToken?`, `reviewerGitAuthorName?`, `reviewerGitAuthorEmail?` to `DispatchReviewerOpts`
- [ ] Inject into `extraEnv`: when reviewer vars are set, override `GITHUB_TOKEN`, `GIT_AUTHOR_EMAIL`, `GIT_AUTHOR_NAME` with reviewer values
- [ ] Update `main.ts`: read the three `REVIEWER_*` vars from `process.env`; pass to `dispatchReviewer()` call
- [ ] Update `technical_skills/review-pr/SKILL.md`: prefer `REVIEWER_GITHUB_TOKEN` for both API calls; retain `reviewer_self_review_skipped` fallback
- [ ] Run tests — verify reviewer executor env contains `REVIEWER_GITHUB_TOKEN` when set; verify fallback to `GITHUB_TOKEN` when absent
- [ ] Open PR targeting `feature/autonomous-feature-reviewer`

---

## T2 — Lifecycle Manager wiring + Handoff Trigger extension

### Description

Two related gaps in the orchestrator's feature lifecycle, both touched in `main.ts` + `handoff-trigger.ts`:

**Gap 1 — Management repo draft PR never fires.**
`runFeatureBranchLifecycle` in `main.ts` is called without `githubToken`, `repoOwner`, or `repoName`. Step 4 of `ensureFeatureBranch` (open draft PR) is silently skipped on every orchestrator start. Fix: pass the management repo coordinates from `parseManagementRepoCoords()` to `runFeatureBranchLifecycle`.

**Gap 2 — No impl repo feature branch PRs.**
The Handoff Trigger (`handoff-trigger.ts`) opens a PR in the management repo only (`parseManagementRepoCoords()`). This task extends it to also open a feature branch PR (`feature/{feature_id}` → base branch) in each implementation repo the feature touched, then write the results as `impl_feature_prs` in `status.yaml`.

`impl_feature_prs` schema (authoritative — see technical design §4):
```yaml
impl_feature_prs:
  - repo: workflow          # matches workspace.yaml repos[].id
    url: https://github.com/...
    status: open            # "open" | "merged"
```

Idempotency: if `impl_feature_prs` is already populated, skip — do not overwrite or duplicate.

### Required skills

- `typescript-best-practices`

### Subtasks

- [ ] Read `lifecycle-manager.ts` `ensureFeatureBranch()` — confirm Step 4 signature (needs `githubToken`, `repoOwner`, `repoName`)
- [ ] Update `main.ts` `runFeatureBranchLifecycle` call: pass `githubToken` + management repo coordinates from `parseManagementRepoCoords()`
- [ ] Read `handoff-trigger.ts` — understand current `promoteOrCreateFeaturePr` flow and how impl repo URLs are determined
- [ ] Extend `handoff-trigger.ts`: for each impl repo the feature touched, open a feature branch PR (`feature/{feature_id}` → base branch) using that repo's GitHub coordinates
- [ ] Write `impl_feature_prs` list into `status.yaml` with `status: "open"` per entry; idempotent (check before writing)
- [ ] Run tests — verify `impl_feature_prs` populated correctly; verify idempotency (second run skips); verify management repo draft PR fires
- [ ] Open PR targeting `feature/autonomous-feature-reviewer`

---

## T5 — Fix eligibility/match.ts — feature-branch task dispatch

### Description

`findEligibleTasks` in `runtime/orchestrator/src/eligibility/match.ts` reads task YAML files from the local filesystem, which `syncRepo` in `bootstrap.ts` resets to `origin/main` on every poll cycle. Tasks whose status was updated on a feature branch (e.g. `feature/autonomous-feature-reviewer`) but not yet on `main` are invisible to the dispatcher — they stay `todo` on `main` and are never dispatched.

Fix: in `loadFeatureTasks`, when `status.yaml` contains a `feature_branch` field, read each task YAML from the remote feature branch using `git show origin/<feature_branch>:<relPath>` instead of the local FS. Fall back to the local FS when:
- `feature_branch` is not set in `status.yaml` (pre-existing features)
- `git show` returns a non-zero exit code for a given task (task not yet committed to the feature branch)

This makes the dispatcher branch-aware without changing any existing behaviour.

> **PR target override — merge directly to `main`.**
> This task fixes the orchestrator dispatch mechanism itself. The standard rule (PRs target `feature/autonomous-feature-reviewer`) is explicitly overridden for T5: open the PR against `main` and merge it there. Merging to `main` makes the fix available to the orchestrator immediately and unblocks T3 dispatch without any additional bootstrapping. This is a deliberate, one-time exception documented in technical-design.md §9.

### Required skills

- `typescript-best-practices`

### Subtasks

- [ ] Read `runtime/orchestrator/src/eligibility/match.ts` — locate `loadFeatureTasks`, confirm how `featurePath` and `TASKS_DIR` are resolved, and confirm where `feature_branch` from `status.yaml` is available
- [ ] Update `loadFeatureTasks` (or its caller): when `feature_branch` is set in `status.yaml`, use `git show origin/<feature_branch>:<relPath>` to read each task YAML; parse as YAML; fall back to local FS read on non-zero exit or when field is absent
- [ ] Run tests — task with `status: ready` only on feature branch is dispatched; fall-back to local FS fires when `feature_branch` absent; graceful skip when `git show` fails for a task not yet on the branch
- [ ] Open PR targeting **`main`** (not `feature/autonomous-feature-reviewer` — see PR target override above)

---

## T6 — Fix handle-merged-prs.ts — sibling status map reads feature branch first

### Description

The auto-ready rule in `runtime/orchestrator/src/poll/handle-merged-prs.ts` reads sibling task statuses from `origin/<mgmtBaseBranch>` (`origin/main`) when computing which tasks become `ready` after a done event. In the feature-branch topology, a sibling's terminal state may only exist on the feature branch. T4, for example, depends on T3; when T3 is marked `done` on the feature branch, the auto-ready sibling check reads `main` and sees T3 as `todo` — T4 is never transitioned to `ready`.

Fix: when `status.yaml` contains a `feature_branch` field, try `git show origin/<feature_branch>:<sibRelPath>` first. Use that result if found. Fall back to `git show origin/<mgmtBaseBranch>:<sibRelPath>` when the feature-branch version is not found (task not yet written to the feature branch) or when `feature_branch` is unset (pre-existing features).

> **PR target override — merge directly to `main`.**
> Same rationale as T5: this fix belongs in the orchestrator core. Open the PR against `main` and merge it there. This is a deliberate, one-time exception documented in technical-design.md §9.

### Required skills

- `typescript-best-practices`

### Subtasks

- [ ] Read `runtime/orchestrator/src/poll/handle-merged-prs.ts` around lines 615–625 — confirm the `git show origin/${mgmtBaseBranch}:${sibRelPath}` call site and its error-handling pattern
- [ ] Confirm where `feature_branch` is sourced at this call site (likely from the already-loaded `status.yaml` for the feature)
- [ ] Update the sibling status read: when `feature_branch` is set, try `git show origin/<feature_branch>:<sibRelPath>` first; on error or missing result fall back to `git show origin/<mgmtBaseBranch>:<sibRelPath>`
- [ ] Run tests — sibling with `done` only on feature branch is seen as `done`; fall-back fires when sibling not on feature branch; no change when `feature_branch` unset
- [ ] Open PR targeting **`main`** (not `feature/autonomous-feature-reviewer` — see PR target override above)

---

## T3 — Feature Done Watcher

### Description

New orchestrator poll step `handleFeatureDone` that automatically transitions `feature_status` from `in_handoff` to `done` when all feature PRs are merged. Currently this transition requires manual intervention.

The watcher:
1. Reads all features with `feature_status: in_handoff` from the management repo.
2. For each, reads `handoff_pr_url` (management repo PR) and `impl_feature_prs` (impl repo PRs) from `status.yaml`.
3. Calls the GitHub API to check merge state of each PR.
4. When all are merged: sets `feature_status: done`, commits and pushes the updated `status.yaml` to the management repo's feature branch, emits `feature_done`.

**Backward compatibility:** if `impl_feature_prs` is absent or empty (features in `in_handoff` before this ships), check only `handoff_pr_url` and emit `impl_feature_prs_missing` — no hard failure.

**Error handling:** GitHub API errors are non-fatal — emit an event and continue to the next feature.

Wired into `main.ts` poll loop alongside the existing `handleMergedPrs` step. T3 must merge before T4 to avoid a `main.ts` poll loop conflict.

**Additional dependencies (T5, T6):** T3 also depends on T5 and T6. Until T5 merges, the orchestrator reads task status from `origin/main` — T3 would appear `todo` and never be dispatched even when all prior dependencies are done. T6 ensures the auto-ready sibling check sees sibling terminal states that are only on the feature branch. See technical design §9 for full analysis.

### Required skills

- `typescript-best-practices`

### Subtasks

- [ ] Create `runtime/orchestrator/src/poll/handle-feature-done.ts`
- [ ] Implement: scan all workspaces for `in_handoff` features; read `handoff_pr_url` + `impl_feature_prs` from each `status.yaml`
- [ ] Call GitHub API (`GET /repos/{owner}/{repo}/pulls/{pull_number}`) for each PR; check `merged_at` field
- [ ] All PRs merged → set `feature_status: done`, commit + push `status.yaml` to management repo feature branch; emit `feature_done`
- [ ] `impl_feature_prs` absent or empty → check only `handoff_pr_url`; emit `impl_feature_prs_missing`
- [ ] GitHub API error → emit `feature_done_check_failed`; continue to next feature (non-fatal)
- [ ] Update `main.ts`: wire `handleFeatureDone()` into the poll loop
- [ ] Run tests: all merged → `feature_status: done` committed; one open → no-op; missing field → graceful skip; API error → non-fatal
- [ ] Open PR targeting `feature/autonomous-feature-reviewer`

---

## T4 — Feature Reviewer Daemon

### Description

New orchestrator poll step `runFeatureReviewCycle` that detects when new commits land on the base branch while a feature is `in_handoff`, classifies the impact, and either auto-rebases or escalates to the human.

Runs every `FEATURE_REVIEW_INTERVAL` cycles (default `20`, ~10 min at 30s poll). For each `in_handoff` feature:

1. **Diff check:** compare feature branch to base branch via GitHub compare API. If no new commits since `feature_branch_base_sha`, skip.
2. **File-overlap classification:** compare files changed in new base commits against files changed by this feature's task PRs.
   - No overlap → task-level: auto-rebase feature branch onto new base. On clean rebase, push and notify. On conflict, fall through to feature-level escalation.
   - Overlap exists → run optional Claude API semantic analysis (confidence threshold 0.80, configurable).
     - High confidence no conflict → treat as task-level.
     - Low confidence or semantic conflict → feature-level escalation.
3. **Feature-level escalation:** set `drift_detected: true` + `drift_reason` in `status.yaml`; post Slack escalation message (skip gracefully if `SLACK_WEBHOOK_URL` unset).

Uses `REVIEWER_GITHUB_TOKEN` for any PR comments or reviews posted by the daemon.

T4 is blocked on T3 because both wire into the `main.ts` poll loop — sequential execution avoids a merge conflict on that block.

### Required skills

- `typescript-best-practices`

### Subtasks

- [ ] Create `runtime/orchestrator/src/poll/feature-review-cycle.ts`
- [ ] Implement cycle gating: read `FEATURE_REVIEW_INTERVAL` from env (default `20`); skip cycle if counter not reached
- [ ] Implement diff check: call GitHub compare API for `feature_branch_base_sha..HEAD` on base branch; skip if no new commits
- [ ] Implement file-overlap classifier: extract changed files from new base commits; compare against files in feature task PRs
- [ ] Implement auto-rebase path (task-level): `git rebase origin/<base_branch>` on feature branch; force-push on clean rebase; on conflict fall through to escalation
- [ ] Implement semantic analysis path: call Claude API with diff context + technical-design.md summary; parse confidence score
- [ ] Implement feature-level escalation: write `drift_detected: true` + `drift_reason` to `status.yaml`; POST to `SLACK_WEBHOOK_URL` if set (skip gracefully if unset); use `REVIEWER_GITHUB_TOKEN` for any PR comments
- [ ] Update `main.ts`: read `FEATURE_REVIEW_INTERVAL` from `process.env` (default `20`); wire `runFeatureReviewCycle` into poll loop with cycle counter
- [ ] Run tests: no new commits → skip; no overlap → auto-rebase; clean rebase → push; conflict → escalate; Slack set → message sent; Slack absent → skip; semantic analysis below threshold → escalate
- [ ] Open PR targeting `feature/autonomous-feature-reviewer`
