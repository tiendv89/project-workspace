# Technical Design

## Feature
- Feature ID: `autonomous-feature-reviewer`
- Title: Autonomous Feature Reviewer

---

## Pre-dependencies

The following fixes must be merged into `agent-workflow` **before** T1 or T2 are dispatched. The orchestrator will not produce a management repo workspace PR for any task if these issues are present.

| PR | Repo | Required for | Status |
|---|---|---|---|
| [fix(feature-branch-lifecycle): use -B flag + skip dispatch on branch failure](https://github.com/tiendv89/agent-workflow/pull/110) | `agent-workflow` | T1, T2 (and all future tasks) — without this fix, a stale local feature branch prevents `feature/autonomous-feature-reviewer` from being pushed to origin; task claims open workspace PRs against a missing base and get 422 | Awaiting merge |
| [fix(feature-branch-lifecycle): wire githubToken to draft PR step in multi-feature scan](https://github.com/tiendv89/agent-workflow/pull/111) | `agent-workflow` | All tasks — without this fix, the feature branch → main draft PR is never opened, `handoff_pr_url` stays null, and the orchestrator fires repeated `stuck_handoff` invariant corrections | Awaiting merge |

**Why this blocked T1 and T2 previously:**  
At orchestrator start, `feature/autonomous-feature-reviewer` existed locally from a prior run but was not on origin. `git checkout -b` fatalled ("branch already exists"), the lifecycle manager emitted `feature_branch_lifecycle_error`, and execution continued. Both agents claimed their tasks and tried to open workspace PRs with `base: feature/autonomous-feature-reviewer` — GitHub returned 422 `base field invalid`. Tasks reached `in_review` on the implementation repo but had no management repo PR.

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

Four components, all in the `workflow` repo. Schema and env vars are already applied to `CLAUDE.md` and `.env.template` (done).

**Wave 1 — Reviewer Identity injection (T1, workflow):**
Update orchestrator reviewer executor dispatch to inject `REVIEWER_GITHUB_TOKEN`, `REVIEWER_GIT_AUTHOR_NAME`, `REVIEWER_GIT_AUTHOR_EMAIL` into the reviewer subprocess environment. Update the `review-pr` skill to prefer `REVIEWER_GITHUB_TOKEN` over `GITHUB_TOKEN` when posting GitHub review events — both API calls (issue comment and review event) now succeed without 422. The `reviewer_self_review_skipped` fallback is retained as a safety net.

**Wave 1 — Lifecycle Manager draft PR wiring + Handoff Trigger extension (T2, workflow):**
Fix `runFeatureBranchLifecycle` in `main.ts` to pass `githubToken`, `repoOwner`, and `repoName` (management repo coordinates) so the management repo draft PR step in `ensureFeatureBranch` actually fires. Then extend `handoff-trigger.ts` to open a feature branch PR in each implementation repo that the feature touched, and write the results into `impl_feature_prs` in `status.yaml`.

**Wave 2 — Feature Done Watcher (T3, workflow):**
New orchestrator poll step `handleFeatureDone` that checks all `in_handoff` features. For each, it reads `handoff_pr_url` and `impl_feature_prs` from `status.yaml`, queries the GitHub API for each PR's merge state, and when all are merged transitions `feature_status` to `done`, commits, and pushes the management repo `status.yaml`.

**Wave 2 — Feature Reviewer Daemon (T4, workflow):**
New orchestrator poll step `runFeatureReviewCycle` that runs every `FEATURE_REVIEW_INTERVAL` cycles (default 20, ~10 min at 30s poll). For each `in_handoff` feature: compares feature branch to base branch via GitHub compare API; if no new commits, skips; if new commits, runs classification (file overlap check → optional Claude API semantic analysis); on task-level drift, auto-rebases the feature branch; on feature-level drift, escalates via Slack and sets `drift_detected: true` in `status.yaml`.

### `impl_feature_prs` schema

The following schema is authoritative. T2 writes it; T3 reads it. Already added to `CLAUDE.md` and `.env.template`.

```yaml
impl_feature_prs:           # set by Handoff Trigger (T2) when all tasks done
  - repo: workflow          # matches workspace.yaml repos[].id
    url: https://github.com/org/agent-workflow/pull/123
    status: open            # "open" | "merged"
```

| Field | Type | Notes |
|---|---|---|
| `repo` | string | Must match `workspace.yaml -> repos[].id` for the implementation repo |
| `url` | string | Full GitHub PR URL for the feature branch PR (`feature/{feature_id}` → base branch) in the impl repo |
| `status` | `"open"` \| `"merged"` | Polled and updated by Feature Done Watcher (T3) |

**Lifecycle:** written once by the Handoff Trigger (T2) at handoff time with `status: "open"` for each impl repo the feature touched. The Feature Done Watcher (T3) polls each URL and updates `status` to `"merged"` as PRs close. When all entries plus `handoff_pr_url` are `"merged"`, `feature_status` transitions to `done`.

**Idempotency:** if `impl_feature_prs` is already present in `status.yaml` when the Handoff Trigger runs, it skips — does not overwrite or duplicate.

**Backward compatibility:** if `impl_feature_prs` is absent or empty (features already `in_handoff` before this ships), the Feature Done Watcher checks only `handoff_pr_url` and emits `impl_feature_prs_missing` — no hard failure.

### Environment variables

Added to `CLAUDE.md` and `.env.template`. Referenced by T1 and T4.

| Variable | Required by | Notes |
|---|---|---|
| `REVIEWER_GITHUB_TOKEN` | T1, T4 | PAT for dedicated reviewer GitHub account (`repo` scope) |
| `REVIEWER_GIT_AUTHOR_NAME` | T1 | Display name for reviewer commits/reviews |
| `REVIEWER_GIT_AUTHOR_EMAIL` | T1 | Email for reviewer commits/reviews |
| `FEATURE_REVIEW_INTERVAL` | T4 | Poll cycles between drift checks; default `20` (~10 min at 30s poll) |

---

## 5. Dependency Analysis

### Internal dependencies

| Dependency | Required by | Notes |
|---|---|---|
| `autonomous-task-orchestrator` shipped | Everything | T8 (lifecycle-manager), T9 (handoff-trigger) must be in place. **Already shipped.** |
| Handoff Trigger extended (T2) | T3 | Done Watcher checks `impl_feature_prs`, which T2 populates |
| Feature Done Watcher merged (T3) | T4 | Both T3 and T4 add steps to the `main.ts` poll loop — sequential execution required to avoid merge conflict |

### External dependencies

| Dependency | Required by | Notes |
|---|---|---|
| Second GitHub reviewer account created | T1, T4 | `REVIEWER_GITHUB_TOKEN` must be set in `.env`. Account needs `write` access on all impl repos |
| `ANTHROPIC_API_KEY` | T4 (semantic analysis step) | Already present in env for existing agent runs |
| `SLACK_WEBHOOK_URL` | T4 (escalation) | Optional; graceful skip if unset |

### Unresolved decisions

None. All open questions from the product spec were resolved at approval.

---

## 6. Parallelization / Blocking Analysis

```
T1: Reviewer Identity injection (workflow)
T2: Lifecycle Manager draft PR wiring + Handoff Trigger extension (workflow)
  └── T1, T2 run in parallel — can both begin now, no blockers
  │
  T3: Feature Done Watcher (workflow)
    └── BLOCKED on T2 (impl_feature_prs must be populated by the extended Handoff Trigger before the watcher can check merge state)
    │
    T4: Feature Reviewer Daemon (workflow)
      └── BLOCKED on T3 (both T3 and T4 wire into the main.ts poll loop — sequential execution avoids merge conflict on that section)
```

Note: T1 runs fully in parallel with the T2 → T3 → T4 chain. T1 and T2 both touch `main.ts` but at different call sites (reviewer dispatch vs lifecycle manager startup) — rebase resolves this cleanly. T3 and T4 both add steps to the same poll loop block in `main.ts`, so they must run sequentially.

---

## 7. Repository Impact

| Repo | Tasks | Changes |
|---|---|---|
| `workflow` | T1, T2, T3, T4 | Orchestrator and skill changes — see per-task detail below |

### `workflow` repo — affected files

| File | Tasks | Change |
|---|---|---|
| `runtime/orchestrator/src/pr-response/dispatch-reviewer.ts` | T1 | Add `reviewerGithubToken?`, `reviewerGitAuthorName?`, `reviewerGitAuthorEmail?` to opts; inject into `extraEnv` overriding `GITHUB_TOKEN` and `GIT_AUTHOR_*` when set |
| `runtime/orchestrator/src/main.ts` | T1 | Read `REVIEWER_GITHUB_TOKEN`, `REVIEWER_GIT_AUTHOR_NAME`, `REVIEWER_GIT_AUTHOR_EMAIL` from `process.env`; forward to `dispatchReviewer()` |
| `workflow/technical_skills/review-pr/SKILL.md` | T1 | Prefer `REVIEWER_GITHUB_TOKEN` over `GITHUB_TOKEN`; both API calls (issue comment + review event) use reviewer identity |
| `runtime/orchestrator/src/main.ts` | T2 | Pass `githubToken`, `repoOwner`, `repoName` to `runFeatureBranchLifecycle` so management repo draft PR actually fires |
| `runtime/orchestrator/src/handoff/handoff-trigger.ts` | T2 | Open impl repo feature branch PRs; write `impl_feature_prs` into `status.yaml` |
| `runtime/orchestrator/src/poll/handle-feature-done.ts` | T3 | New file — Feature Done Watcher |
| `runtime/orchestrator/src/main.ts` | T3, T4 | Wire new poll steps into cycle; read `FEATURE_REVIEW_INTERVAL` from `process.env` for T4 |
| `runtime/orchestrator/src/poll/feature-review-cycle.ts` | T4 | New file — Feature Reviewer Daemon cycle step |
| `.env.template` (workflow repo) | T1, T4 | Add `REVIEWER_GITHUB_TOKEN`, `REVIEWER_GIT_AUTHOR_NAME`, `REVIEWER_GIT_AUTHOR_EMAIL`, `FEATURE_REVIEW_INTERVAL` |
| `runtime/orchestrator/templates/.projects/.env.example` | T1, T4 | Add reviewer identity + `FEATURE_REVIEW_INTERVAL` vars with setup comments |
| `runtime/orchestrator/docs/OPERATOR-GUIDE.md` | T1, T4 | Add reviewer identity setup section; add feature reviewer tuning table |

---

## 8. Validation and Release Impact

### Testing expectations

- **T1**: unit test that reviewer executor env contains `REVIEWER_GITHUB_TOKEN`; integration test that `review-pr` skill posts both calls successfully when reviewer token differs from impl token
- **T2**: unit test handoff-trigger populates `impl_feature_prs` with correct repo/url/status fields; test idempotency (already set → skip)
- **T3**: seam tests — all PRs merged → `feature_status: done` written and pushed; one PR still open → no-op; GitHub API error → non-fatal
- **T4**: unit tests for file-overlap classification; mock Claude API for semantic analysis; escalation path with Slack configured; auto-rebase path with clean rebase; rebase conflict → escalate fallback

### Migration / config impact

- Operators must create a second GitHub account, generate a PAT, and add `REVIEWER_GITHUB_TOKEN`, `REVIEWER_GIT_AUTHOR_NAME`, `REVIEWER_GIT_AUTHOR_EMAIL` to `.env` before T1/T4 behaviour takes effect.
- If these vars are absent, the existing T10 two-call workaround continues to operate — no hard failure. The `reviewer_self_review_skipped` event remains a valid operational state until the second account is provisioned.
- `FEATURE_REVIEW_INTERVAL` env var (default `20` cycles) controls how often the drift daemon runs. Already added to `.env.template`.

### Backward compatibility

- Features already `in_handoff` at deploy time have no `impl_feature_prs` in their `status.yaml`. The Feature Done Watcher must handle the missing field gracefully: if `impl_feature_prs` is absent or empty, only check `handoff_pr_url`. Emit a `impl_feature_prs_missing` event and continue.
- Features that transitioned to `done` manually (before this feature ships) are unaffected — the watcher only acts on `in_handoff` features.

### Handoff document location

Committed to `docs/features/{feature_id}/handoffs/handoff.md` in the management repo feature branch — consistent with all prior features. Not a PR description.

### Rollout

No flag needed. All new code paths are additive. The Feature Done Watcher and Feature Reviewer Daemon activate only for features in `in_handoff` — features in earlier stages are unaffected.

---

## 9. Bug Fix Amendments — Feature-Branch Dispatch Gap

Discovered during T2 implementation and verified against the live orchestrator codebase.

### Finding 1 — `findEligibleTasks` reads task status from `main`, not the feature branch

When task branches merge into `feature/<id>` (the standard topology), the orchestrator's eligibility check is blind to feature-branch state:

1. Every poll cycle, `syncRepo` in `bootstrap.ts` checks out and hard-resets the management repo workspace to `origin/<baseBranch>` (`origin/main`).
2. `findEligibleTasks` in `eligibility/match.ts` calls `loadFeatureTasks`, which reads task YAML files from the local filesystem — now reset to `main`.
3. When T2's task branch merged into `feature/autonomous-feature-reviewer`, the auto-ready rule wrote T3's status to `ready` on that feature branch — not on `main`. `main` still shows T3 as `todo`.
4. Criterion 1 in `findEligibleTasks` (`task.status !== "ready"`) evaluates against the `main` copy — T3 is never dispatched.

**Root cause:** `loadFeatureTasks` uses `join(featurePath, TASKS_DIR)` on the local FS, which tracks `origin/main` after `syncRepo`. It must read from `origin/<feature_branch>` when the feature has an active feature branch recorded in `status.yaml`.

**Code location:** `runtime/orchestrator/src/eligibility/match.ts` — `loadFeatureTasks` and its caller.

### Finding 2 — Auto-ready sibling status map reads from `origin/main`

In `handle-merged-prs.ts` (~line 619), the auto-ready rule reads sibling task statuses from `origin/<mgmtBaseBranch>` to decide which tasks become `ready` after a done event. In the feature-branch topology, a sibling's terminal state may only exist on the feature branch. A future task (e.g. T4) whose dependency chain runs through T3 would fail to auto-ready: T3's `done` state is on the feature branch, but the sibling map reads `main` and sees `todo`.

**Code location:** `runtime/orchestrator/src/poll/handle-merged-prs.ts` — `git show origin/${mgmtBaseBranch}:${sibRelPath}` call.

### Solution

**Fix 1 (T5) — `eligibility/match.ts`:**
In `loadFeatureTasks`, when `status.yaml` has a `feature_branch` field set, read each task YAML from the remote feature branch using `git show origin/<feature_branch>:<relPath>`. Fall back to the local FS when `feature_branch` is absent (pre-existing features) or when `git show` returns a non-zero exit for a task not yet on the feature branch.

**Fix 2 (T6) — `handle-merged-prs.ts`:**
In the auto-ready sibling status map, try `git show origin/<feature_branch>:<sibRelPath>` first when `feature_branch` is set in `status.yaml`. Fall back to `git show origin/<mgmtBaseBranch>:<sibRelPath>` when the feature-branch version is not found or `feature_branch` is unset.

### Updated dependency graph

T5 and T6 are new Wave 1 tasks (no dependencies) that must merge before T3 can be safely dispatched. T3's `depends_on` is updated to `[T2, T5, T6]`.

```
T1: Reviewer Identity injection (workflow)
T2: Lifecycle Manager wiring + Handoff Trigger extension (workflow)
T5: Fix eligibility/match.ts — loadFeatureTasks reads from feature branch (workflow)
T6: Fix handle-merged-prs.ts — sibling status map checks feature branch first (workflow)
  └── T1, T2, T5, T6 all run in Wave 1 — no dependencies between them

T3: Feature Done Watcher (workflow)
  └── BLOCKED on T2, T5, T6

T4: Feature Reviewer Daemon (workflow)
  └── BLOCKED on T3
```

### Bootstrapping note — T5 and T6 merge directly to `main`

T5 and T6 fix the orchestrator's dispatch mechanism itself. The standard feature-branch topology (task PRs target `feature/autonomous-feature-reviewer`) is **explicitly overridden** for these two tasks: T5 and T6 open their implementation PRs against `main` and merge there directly.

**Rationale:** merging to `main` makes both fixes available to the orchestrator immediately. The orchestrator reads from `origin/main` after `syncRepo` — so once T5 and T6 are on `main`, every subsequent feature-branch task (T3, T4) dispatches and auto-readies correctly without any further manual intervention.

After T5 and T6 merge to `main`, the orchestrator will read T3's state from `origin/feature/autonomous-feature-reviewer` (T5's fix) and correctly evaluate the auto-ready sibling map (T6's fix). T3 transitions to `ready` automatically and the rest of the feature proceeds under normal rules.

### Finding 3 — lifecycle manager runs only at startup; deleted feature branches are never recreated

`runFeatureBranchLifecycle` is called once in the orchestrator startup block (`main.ts:~282`). If the feature branch is deleted while the orchestrator is running (e.g. a workspace PR is merged mid-session), subsequent claim attempts fail with `workspace_pr_failed` HTTP 422 because `openWorkspacePr` is passed `featureBranchName(featureId)` as the base and the branch no longer exists.

**Fix (T7):** move `runFeatureBranchLifecycle` from the startup path into the top of every poll cycle. The lifecycle manager is idempotent — branch already exists → no-op. With this fix, a deleted feature branch is recreated on the next poll cycle, before any claim or workspace PR creation is attempted. T7 also merges directly to `main`.

### Updated dependency graph

```
T1, T2, T5, T6, T7 — Wave 1, all independent

T3 — Wave 2, blocked on T2, T5, T6
T4 — Wave 3, blocked on T3
```

T7 has no dependency on T5 or T6 — it can land in any order within Wave 1.

### Updated repository impact

| File | Task | Change |
|---|---|---|
| `runtime/orchestrator/src/eligibility/match.ts` | T5 | `loadFeatureTasks`: use `git show origin/<feature_branch>:<relPath>` when `feature_branch` is set |
| `runtime/orchestrator/src/poll/handle-merged-prs.ts` | T6 | Sibling status map: try `origin/<feature_branch>` first, fall back to `origin/<mgmtBaseBranch>` |
| `runtime/orchestrator/src/main.ts` | T7 | Move `runFeatureBranchLifecycle` from startup into the top of every poll cycle |
