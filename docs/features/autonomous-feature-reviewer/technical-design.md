# Technical Design

## Feature
- Feature ID: `autonomous-feature-reviewer`
- Title: Autonomous Feature Reviewer

---

## 1. Current State

The `autonomous-task-orchestrator` feature shipped the following components that this feature builds on top of:

| Component | Status | Location | Notes |
|---|---|---|---|
| Feature Branch Lifecycle Manager | **shipped** (T8) | `runtime/orchestrator/src/feature-branch/lifecycle-manager.ts` | Creates/syncs management repo feature branch; records `feature_branch` + `feature_branch_base_sha` in `status.yaml` |
| Draft management repo PR on branch creation | **partial** (T9) | `ensureFeatureBranch()` Step 4 | Step 4 is implemented but `runFeatureBranchLifecycle` in `main.ts` is called without `githubToken`/`repoOwner`/`repoName` — draft PR is **never fired** |
| Handoff Trigger + handoff.md generation | **shipped** (T9) | `runtime/orchestrator/src/handoff/handoff-trigger.ts` | Generates `handoffs/handoff.md`; promotes management repo draft PR → ready-for-review; uses `parseManagementRepoCoords()` — **management repo only** |
| Task PRs target `feature/{feature_id}` | **shipped** (T8/T9) | `runtime/orchestrator/src/side-effects/dispatch.ts` | Task branch PRs merge into feature branch, not base |
| Reviewer agent dispatch + `review-pr` skill | **shipped** (T2/T3) | `runtime/orchestrator/`, `workflow_skills/review-pr/` | Reviewer uses same bot token as impl agent |

> **Code-verified:** Both `lifecycle-manager.ts` and `handoff-trigger.ts` were read directly. The `fireHandoffTrigger` call in `dispatch-review-result.ts` passes `parseManagementRepoCoords()` coordinates — the PR it opens is in the **management repo** only. No implementation repo PR is opened anywhere in the current codebase.

What the orchestrator does **not** yet do:

1. **Management repo draft PR not firing**: `runFeatureBranchLifecycle` in `main.ts` does not pass `githubToken`, `repoOwner`, or `repoName` to `ensureFeatureBranch`. Step 4 (draft PR open) is silently skipped on every orchestrator start. This needs to be wired up.

2. **Reviewer identity**: the reviewer agent authenticates as the same bot account that opens implementation PRs. GitHub returns HTTP 422 on self-reviews. The T10 workaround (two-call pattern) retains the issue comment but drops the structured review event. A dedicated reviewer GitHub account eliminates the root cause.

3. **Implementation repo feature PRs**: the Handoff Trigger promotes the management repo draft PR to ready-for-review but does **not** open a feature branch PR in the implementation repo (e.g. `workflow`). The human has no single PR to review in the actual implementation repo.

4. **`impl_feature_prs` tracking**: no field in `status.yaml` records implementation repo feature PRs. The orchestrator has no way to detect when those PRs are merged.

5. **Feature Done Watcher**: `feature_status` never transitions to `done` automatically. The human or a manual script currently does this. No daemon watches for all feature PRs to merge.

6. **Feature Reviewer Daemon**: no drift detection exists. If commits land on `main` while a feature is `in_handoff`, agents continue working against a potentially stale technical design.

---

## 2. Problem Framing

Six concrete gaps to close:

| Gap | Effect |
|---|---|
| `runFeatureBranchLifecycle` never passes GitHub credentials | Management repo draft PR (Step 4 of `ensureFeatureBranch`) silently skipped on every orchestrator start |
| Same bot reviews its own PRs | Structured `APPROVE`/`REQUEST_CHANGES` event lost on HTTP 422 |
| Impl repo has no feature-level PR | Human must diff across task commits; no single PR to review in the implementation repo |
| `impl_feature_prs` not tracked | Done detection impossible without manual intervention |
| No Feature Done Watcher | `feature_status` stuck at `in_handoff` indefinitely |
| No drift detection | Stale technical designs go undetected until merge-time conflict |

**What must remain stable:**
- Existing task-level PR lifecycle (draft → promote → demote) is unchanged.
- The `handoff_pr_url` field (management repo PR) remains the primary orchestrator-side status field — `impl_feature_prs` is additive.
- All CLAUDE.md branch, rebase, and management repo write rules continue to apply.
- The `feature_branch_base_sha` field (written by T8) is the baseline for drift detection — never overwritten.

---

## 3. Options Considered

### Option A — Feature Reviewer Daemon as separate process

Run a dedicated Node.js process alongside the orchestrator that polls GitHub for drift.

- Pros: clean separation of concerns; can be scaled independently; failure does not affect orchestrator
- Cons: new process to deploy and monitor; shared file-system access to management repo workspace requires coordination; adds operational complexity

### Option B — Feature Reviewer Daemon integrated into orchestrator poll loop (chosen)

Add a `runFeatureReviewCycle()` step to the existing orchestrator poll loop, similar to how `handleMergedPrs` and `runStateInvariantCheck` run today.

- Pros: single process to deploy; shares existing management repo workspace path and GitHub token plumbing; consistent with how all other feature-level side effects are handled
- Cons: drift classification involves a Claude API call, which adds latency to the poll cycle — mitigated by running the classification step with a separate configurable interval

**Decision: Option B.** The orchestrator is already the correct home for all feature lifecycle management. Adding feature review as a cycle step is consistent with the existing pattern.

### Option C — Reviewer identity via GitHub App instead of second PAT

Use a GitHub App installation token for the reviewer identity, avoiding the need to create and manage a second personal account.

- Pros: cleaner GitHub security model; tokens auto-rotate
- Cons: requires GitHub App setup, installation, and token exchange logic — meaningfully more complexity than a second PAT for an alpha-stage system
- Decision: deferred. Second PAT is sufficient for now.

---

## 4. Chosen Design

Five components, built in waves:

**Wave 1 — Schema and environment (T1, management-repo):**
Add `impl_feature_prs` schema to `CLAUDE.md` status.yaml table and add the three reviewer identity env vars to `.env.template`. No code changes.

**Wave 2 — Reviewer Identity injection (T2, workflow):**
Update orchestrator reviewer executor dispatch to inject `REVIEWER_GITHUB_TOKEN`, `REVIEWER_GIT_AUTHOR_NAME`, `REVIEWER_GIT_AUTHOR_EMAIL` into the reviewer subprocess environment. Update the `review-pr` skill to prefer `REVIEWER_GITHUB_TOKEN` over `GITHUB_TOKEN` when posting GitHub review events — both API calls (issue comment and review event) now succeed without 422. The `reviewer_self_review_skipped` fallback is retained as a safety net.

**Wave 2 — Lifecycle Manager draft PR wiring + Handoff Trigger extension (T3, workflow):**
Fix `runFeatureBranchLifecycle` in `main.ts` to pass `githubToken`, `repoOwner`, and `repoName` (management repo coordinates) so the management repo draft PR step in `ensureFeatureBranch` actually fires. Then extend `handoff-trigger.ts` to open a feature branch PR in each implementation repo that the feature touched, and write the results into `impl_feature_prs` in `status.yaml`.

**Wave 3 — Feature Done Watcher (T4, workflow):**
New orchestrator poll step `handleFeatureDone` that checks all `in_handoff` features. For each, it reads `handoff_pr_url` and `impl_feature_prs` from `status.yaml`, queries the GitHub API for each PR's merge state, and when all are merged transitions `feature_status` to `done`, commits, and pushes the management repo `status.yaml`.

**Wave 3 — Feature Reviewer Daemon (T5, workflow):**
New orchestrator poll step `runFeatureReviewCycle` that runs every `FEATURE_REVIEW_INTERVAL` cycles (default 20, ~10 min at 30s poll). For each `in_handoff` feature: compares feature branch to base branch via GitHub compare API; if no new commits, skips; if new commits, runs classification (file overlap check → optional Claude API semantic analysis); on task-level drift, auto-rebases the feature branch; on feature-level drift, escalates via Slack and sets `drift_detected: true` in `status.yaml`.

---

## 5. Dependency Analysis

### Internal dependencies

| Dependency | Required by | Notes |
|---|---|---|
| `autonomous-task-orchestrator` shipped | Everything | T8 (lifecycle-manager), T9 (handoff-trigger) must be in place. **Already shipped.** |
| `impl_feature_prs` in CLAUDE.md (T1) | T3, T4 | Schema must be documented before code that populates/reads it |
| Handoff Trigger extended (T3) | T4 | Done Watcher checks `impl_feature_prs`, which T3 populates |
| Reviewer identity env vars (T1) | T2 | Env var names must be agreed before code references them |

### External dependencies

| Dependency | Required by | Notes |
|---|---|---|
| Second GitHub reviewer account created | T2, T5 | `REVIEWER_GITHUB_TOKEN` must be set in `.env`. Account needs `write` access on all impl repos |
| `ANTHROPIC_API_KEY` | T5 (semantic analysis step) | Already present in env for existing agent runs |
| `SLACK_WEBHOOK_URL` | T5 (escalation) | Optional; graceful skip if unset |

### Unresolved decisions

None. All open questions from the product spec were resolved at approval.

---

## 6. Parallelization / Blocking Analysis

```
T1: Schema + env template additions (management-repo)
  └── Can begin now — no blockers

T2: Reviewer Identity injection (workflow)
T3: Handoff Trigger extension — impl repo feature PRs (workflow)
T5: Feature Reviewer Daemon (workflow)
  └── T2, T3, T5 run in parallel
  └── Can begin now (T1 is documentation-only; code can proceed against agreed env var names)
  │
  T4: Feature Done Watcher (workflow)
    └── BLOCKED on T3 (impl_feature_prs must be populated by the extended Handoff Trigger before the watcher can check merge state)
```

Note: T2 and T5 are both independent of T3/T4 and of each other. The reviewer identity (T2) has no bearing on drift detection (T5). T4 is the only task with a hard dependency.

---

## 7. Repository Impact

| Repo | Tasks | Changes |
|---|---|---|
| `management-repo` | T1 | `CLAUDE.md` — add `impl_feature_prs` to `status.yaml` fields table; `.env.template` — add `REVIEWER_GITHUB_TOKEN`, `REVIEWER_GIT_AUTHOR_NAME`, `REVIEWER_GIT_AUTHOR_EMAIL` |
| `workflow` | T2, T3, T4, T5 | Orchestrator and skill changes — see per-task detail below |

### `workflow` repo — affected files

| File | Tasks | Change |
|---|---|---|
| `runtime/orchestrator/src/briefing/reviewer-briefing.ts` | T2 | Inject `REVIEWER_*` env vars into reviewer subprocess env |
| `workflow/technical_skills/review-pr/SKILL.md` | T2 | Prefer `REVIEWER_GITHUB_TOKEN`; both API calls (issue comment + review event) use reviewer identity |
| `runtime/orchestrator/src/main.ts` | T3 | Pass `githubToken`, `repoOwner`, `repoName` to `runFeatureBranchLifecycle` so management repo draft PR actually fires |
| `runtime/orchestrator/src/handoff/handoff-trigger.ts` | T3 | Open impl repo feature branch PRs; write `impl_feature_prs` into `status.yaml` |
| `runtime/orchestrator/src/poll/handle-feature-done.ts` | T4 | New file — Feature Done Watcher |
| `runtime/orchestrator/src/main.ts` | T4, T5 | Wire new poll steps into cycle |
| `runtime/orchestrator/src/poll/feature-review-cycle.ts` | T5 | New file — Feature Reviewer Daemon cycle step |
| `.env.template` (workflow repo copy, if present) | T2 | Add reviewer identity vars |

---

## 8. Validation and Release Impact

### Testing expectations

- **T2**: unit test that reviewer executor env contains `REVIEWER_GITHUB_TOKEN`; integration test that `review-pr` skill posts both calls successfully when reviewer token differs from impl token
- **T3**: unit test handoff-trigger populates `impl_feature_prs` with correct repo/url/status fields; test idempotency (already set → skip)
- **T4**: seam tests — all PRs merged → `feature_status: done` written and pushed; one PR still open → no-op; GitHub API error → non-fatal
- **T5**: unit tests for file-overlap classification; mock Claude API for semantic analysis; escalation path with Slack configured; auto-rebase path with clean rebase; rebase conflict → escalate fallback

### Migration / config impact

- Operators must create a second GitHub account, generate a PAT, and add `REVIEWER_GITHUB_TOKEN`, `REVIEWER_GIT_AUTHOR_NAME`, `REVIEWER_GIT_AUTHOR_EMAIL` to `.env` before T2/T5 behaviour takes effect.
- If these vars are absent, the existing T10 two-call workaround continues to operate — no hard failure. The `reviewer_self_review_skipped` event remains a valid operational state until the second account is provisioned.
- New `FEATURE_REVIEW_INTERVAL` env var (default `20` cycles) controls how often the drift daemon runs. Add to `.env.template`.

### Backward compatibility

- Features already `in_handoff` at deploy time have no `impl_feature_prs` in their `status.yaml`. The Feature Done Watcher must handle the missing field gracefully: if `impl_feature_prs` is absent or empty, only check `handoff_pr_url`. Emit a `impl_feature_prs_missing` event and continue.
- Features that transitioned to `done` manually (before this feature ships) are unaffected — the watcher only acts on `in_handoff` features.

### Handoff document location

Committed to `docs/features/{feature_id}/handoffs/handoff.md` in the management repo feature branch — consistent with all prior features. Not a PR description.

### Rollout

No flag needed. All new code paths are additive. The Feature Done Watcher and Feature Reviewer Daemon activate only for features in `in_handoff` — features in earlier stages are unaffected.
