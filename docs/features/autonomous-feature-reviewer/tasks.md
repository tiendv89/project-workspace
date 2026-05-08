# Task Breakdown — Autonomous Feature Reviewer

**Feature status:** `in_tdd` | **Stage:** `tasks` (awaiting approval) | Machine state lives in `tasks/T<n>.yaml`

---

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Reviewer Identity injection | — |
| T2 | 1 | Lifecycle Manager wiring + Handoff Trigger extension | — |
| T3 | 2 | Feature Done Watcher | T2 |
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
