# Technical Design — Handoff PR Flow Redesign

- Feature ID: `handoff-pr-redesign`
- Stage: `technical_design`
- Status: draft

---

## 1. Current State

### Orchestrator main loop (one poll cycle)

`main.ts → runOneCycle()` — all steps run **sequentially** (no within-cycle parallelism). The cycle repeats every `idle_sleep_seconds`.

```
Legend
  [S-git]    Sync-blocking git — execSync(); blocks the Node.js event loop
  [S-http]   Sync-blocking HTTP — curl via spawnSync(); blocks event loop
  [A-http]   Async HTTP — fetch() / awaited curl; yields to event loop
  [FF]       Fire-and-forget — submitted to broker; result arrives in a FUTURE cycle
  ──────────────────────────────────────────────────────────────────────────────────

 sleep(idle_sleep_seconds)
       │
       ▼
 runOneCycle() ──────────────────────────────────────────────────────────────────
 │
 │  [S-git]
 ├─ 1. pullWorkspaces
 │       syncRepo() × (workflow repo + N mgmt repos + N impl repos)
 │       git fetch origin
 │       git checkout <baseBranch>
 │       git reset --hard origin/<baseBranch>
 │       ↳ skips impl repo pull if a subprocess executor is in-flight
 │         (prevents syncRepo from switching the shared working tree mid-execution)
 │
 │  [S-git] + [S-http]
 ├─ 2. runFeatureBranchLifecycle   (per feature with eligible feature_status)
 │       git ls-remote, checkout, push  →  ensure feature/{id} exists on origin
 │       git ls-remote, checkout, push  →  ensure feature/{id} on each impl repo
 │       GitHub REST POST /pulls        →  open draft PR on first creation  [S-http]
 │       GraphQL markPrReadyForReview   →  promote draft if in_handoff  [S-http]
 │       Writes: status.yaml (feature_branch, feature_branch_base_sha, handoff_pr_url)
 │
 │  ╔═══════════════════════════════════════════════════════════════════════════╗
 │  ║  dispatchBlock — skipped entirely when executor pool is full             ║
 │  ║  (local-subprocess: max 1 in-flight; local-docker: configurable)        ║
 │  ║                                                                          ║
 │  ║  [A-http] + [S-git] + [FF]                                              ║
 │  ║  ├─ 3. Eligible-task dispatch   (first eligible task, then break)        ║
 │  ║  │       findEligibleTasks  →  read task YAMLs + tasks.md               ║
 │  ║  │       claimTask          →  git commit/push (claim)  [S-git]         ║
 │  ║  │       openWorkspacePr    →  GitHub REST POST /pulls  [S-http]        ║
 │  ║  │       fetchRagContext    →  HTTP MCP call (optional)  [A-http]       ║
 │  ║  │       generateBriefing   →  in-process template render               ║
 │  ║  │       adapter.submit()   ──────────────────────────────────── [FF] ──┐║
 │  ║  │                                                                      │║
 │  ║  │  (only if step 3 found no eligible task)                             │║
 │  ║  │  [S-git] + [FF]                                                      │║
 │  ║  ├─ 4. Fix-agent dispatch   (first change_requested task, then break)   │║
 │  ║  │       findFixableTasks   →  read task YAMLs                         │║
 │  ║  │       claimFixTask       →  git commit/push  [S-git]                │║
 │  ║  │       generateFixBriefing →  in-process                             │║
 │  ║  │       adapter.submit()   ──────────────────────────────────── [FF] ──┤║
 │  ║  │                                                                      │║
 │  ║  │  (only if steps 3–4 found nothing)                                   │║
 │  ║  │  [S-git] + [FF]                                                      │║
 │  ║  └─ 5. Reviewer dispatch   (first in_review task, then break)           │║
 │  ║          findReviewableTasks →  read task YAMLs                        │║
 │  ║          dispatchReviewer   →  git log entry/push  [S-git]             │║
 │  ║          adapter.submit()   ──────────────────────────────────── [FF] ──┘║
 │  ║                                                                          ║
 │  ║  Executors run as independent Claude CLI subprocesses (local-subprocess) ║
 │  ║  or Docker containers (local-docker). They post result.json to the      ║
 │  ║  broker when done. The orchestrator does NOT wait — it continues to     ║
 │  ║  steps 6–10 immediately.                                                ║
 │  ╚═══════════════════════════════════════════════════════════════════════════╝
 │
 │  (rate-limited by pr_poll_interval_seconds; skipped if subprocess in-flight)
 │  [S-http] + [S-git] + optional [A] Claude subprocess
 ├─ 6. PR poll
 │       checkInReviewPrs         →  GitHub REST GET /pulls per in-review task  [S-http]
 │       handleMergeConflicts     →  git rebase  [S-git]
 │       │                           Claude CLI subprocess for YAML conflict resolution
 │       │                           (ad-hoc spawn, not a skill — awaited to completion)
 │       handleMergedPrs          →  git checkout/commit/push  [S-git]
 │       │                           GitHub REST PUT /pulls/{n}/merge  [S-http]
 │       │                           Writes: task YAML (done), sibling YAMLs (ready cascade)
 │       │                           └─ if last task done → fireHandoffTrigger
 │       │                                git commit/push handoff.md  [S-git]
 │       │                                GitHub REST POST /pulls  [S-http]
 │       │                                Writes: status.yaml (in_handoff, handoff_pr_url)
 │       handleWorkspacePrRecoveries →  GitHub REST retry merge  [S-http]
 │
 │  [S-http] + [S-git]
 ├─ 7. Feature Done Watcher   (handleFeatureDone)
 │       GitHub REST GET /pulls  →  check merge state of handoff_pr_url  [S-http]
 │       GitHub REST GET /pulls  →  check merge state of impl_feature_prs  [S-http]
 │       git checkout feature/{id} + write status.yaml (done) + push  [S-git]
 │       ↳ BUG: checkout fails when feature/{id} deleted after PR merge
 │
 │  (every FEATURE_REVIEW_INTERVAL cycles — default 20)
 │  [S-http] + [S-git] + optional [FF] Claude subprocess
 ├─ 8. Feature Review Daemon   (runFeatureReviewCycle)
 │       git merge-base; GitHub REST drift check  [S-git] [S-http]
 │       git rebase for task-level drift  [S-git]
 │       Claude subprocess (reviewer) for feature-level conflict  [FF]
 │
 │  (every STATE_INVARIANT_CHECK_INTERVAL cycles — default 5)
 │  [S-git] + YAML reads
 ├─ 9. State Invariant Checker   (runStateInvariantCheck)
 │       git show origin/<branch>:<path>  [S-git]
 │       parseYaml; sanity checks against expected invariants
 │
 │  [A-http (broker)] + [S-git] + [S-http]
 └─ 10. Reap Loop   (runReapLoop)
         broker.listCompleted()  →  drain up to 10 results  [A-http or in-memory]
         per completion, route by handle.kind:
           kind = "impl"        →  dispatchExecutorResult
                                    git task YAML mutation (done + cascade)  [S-git]
                                    GitHub REST (open impl PR if needed)  [S-http]
           kind = "review"      →  dispatchReviewResult
                                    writeDoneAndCascade: git  [S-git]
                                    └─ if all done: fireHandoffTrigger (see step 6)
           kind = "review-fix"  →  emit review_dispatch_complete (in-process only)
         broker.ack() / broker.nack()

       ◄──── executor results posted here by subprocesses from steps 3–5
             (in-memory queue for local-subprocess; HTTP broker for local-docker)

 └── sleep(idle_sleep_seconds) → repeat
```

### Current process-level state map

#### Feature Branch Lifecycle Manager (`feature-branch/lifecycle-manager.ts`)

**Reads:**
- `git ls-remote origin refs/heads/feature/{id}` — branch existence check
- `status.yaml` (via `git show origin/{baseBranch}:...`) — reads `feature_branch`, `feature_branch_base_sha`, `handoff_pr_url`, `feature_status`
- `workspace.yaml` — resolves impl repo IDs and base branches

**Writes:**
- Creates `feature/{id}` on origin if absent; records `feature_branch` + `feature_branch_base_sha` in `status.yaml`, commits to feature branch
- **Step 4 (first creation):** opens a **draft PR**: `feature/{id}` → `baseBranch` (main) via GitHub REST API; records URL as `status.yaml.handoff_pr_url`
- **Step 5 (in_handoff guard):** re-promotes the PR from `handoff_pr_url` from draft to ready-for-review via GraphQL if it is still a draft; writes `handoff_pr_promoted: true` sentinel to `status.yaml` using `--force-with-lease` CAS push

**Skill vs code:** pure TypeScript code — no Claude skill delegation.

#### Claim + Executor dispatch (`claim/claim-task.ts`, `main.ts`)

**Reads:** task YAML status (`ready`), dependency statuses, workspace.yaml

**Writes:**
- `task.status = "in_progress"` + `log.claimed` entry in task YAML; commits + pushes to task branch (claim commit)
- Opens workspace PR: `task-branch/{featureId}/{taskId}` → `feature/{id}` via GitHub REST API; records `workspace_pr.url` in task YAML

**Skill vs code:** orchestrator code handles claim; executor is a Claude subprocess launched with a text briefing.

#### handleMergedPrs (`poll/handle-merged-prs.ts`)

Fires when `checkInReviewPrs` reports `merged: true` for an impl-repo task PR.

**Reads:** task YAML from task branch, sibling task YAMLs, `status.yaml.feature_branch`

**Writes:**
- `task.status = "done"`, `pr.status = "merged"`, `log.done` in task YAML on task branch; commits + pushes
- Auto-ready rule: reads sibling YAMLs, sets `status: ready` + `log.ready` for any whose `depends_on` are now all done
- Merges workspace PR (`task-branch` → `feature/{id}`) via GitHub REST API
- If all tasks done: calls `fireHandoffTrigger`

**Skill vs code:** pure orchestrator code; Claude is spawned only for YAML conflict resolution (ad-hoc, not a skill).

#### Handoff Trigger (`handoff/handoff-trigger.ts`)

**Current behavior** — fires from `handleMergedPrs` when `checkAllTasksDone` returns true.

**Reads:**
- Task YAMLs, `product-spec.md`, task PR file lists from GitHub REST API

**Writes:**
- Generates `handoff.md` and commits it to `feature/{id}` branch
- Calls `promoteOrCreateFeaturePr`: promotes the PR already recorded at `status.yaml.handoff_pr_url` (the draft `feature/{id}` → `main` PR opened by the Lifecycle Manager) from draft to ready-for-review
- Sets `status.yaml.handoff_pr_url`, `feature_status: in_handoff`, `current_stage: handoff`; commits + pushes to feature branch
- Slack notification via webhook

**Key constraint:** the PR it promotes is `feature/{id}` → `main`. When a human merges it, GitHub deletes `feature/{id}`.

**Skill vs code:** pure orchestrator code.

#### Feature Done Watcher (`poll/handle-feature-done.ts`)

**Reads:**
- `status.yaml` (first tries `git show origin/feature/{id}:...`, falls back to local FS)
- GitHub REST API: PR merge state for `handoff_pr_url` and each `impl_feature_prs` entry

**Current writes (when all PRs merged):**
- `git checkout -B feature/{id} origin/feature/{id}` ← **THIS FAILS** after the PR is merged, because GitHub deletes `feature/{id}` on merge
- `status.yaml.feature_status = "done"`, commits + pushes to feature branch
- Emits `feature_done`

**What it does NOT do:**
- Does not auto-merge any PR
- Does not write `current_stage: done`

**Known gaps:**
- `impl_feature_prs` is never populated by any code → `impl_feature_prs_missing` emitted every cycle
- `handoff_pr_url` currently points to `feature/{id}` → `main`; merging it deletes the feature branch; the checkout in step 4 above then fails

**Skill vs code:** pure orchestrator code.

### Current `status.yaml` fields written by the orchestrator

| Field | Written by | Value |
|---|---|---|
| `feature_branch` | Lifecycle Manager | `feature/{id}` |
| `feature_branch_base_sha` | Lifecycle Manager | merge-base SHA at branch creation |
| `handoff_pr_url` | Lifecycle Manager (draft, on creation) + Handoff Trigger (same URL, promoted) | URL of `feature/{id}` → `main` |
| `impl_feature_prs` | **Nobody — gap** | never set |
| `handoff_pr_promoted` | Lifecycle Manager step 5 | boolean sentinel |
| `feature_status` | Handoff Trigger (`in_handoff`) + Feature Done Watcher (`done`) | lifecycle state |
| `current_stage` | Handoff Trigger (`handoff`) | stage name |

---

## 2. Problem Framing

Three interconnected bugs in the current handoff flow:

**Bug 1 — Feature branch deleted before done state can be written.**
`handoff_pr_url` points to `feature/{id}` → `main`. When a human merges this PR, GitHub auto-deletes `feature/{id}`. The Feature Done Watcher's next poll tries `git checkout -B feature/{id} origin/feature/{id}` — this command fails because the remote ref no longer exists. The watcher emits `feature_done_check_failed` and the feature is stuck in `in_handoff` forever.

**Bug 2 — `impl_feature_prs` is never populated.**
No code path writes `impl_feature_prs`. The Handoff Trigger only opens/promotes the management repo PR. The Feature Done Watcher emits `impl_feature_prs_missing` every cycle and falls back to checking only `handoff_pr_url`.

**Bug 3 — No auto-merge of the workspace feature PR.**
The `feature_done` event is emitted but nothing acts on it. A human must manually merge the workspace feature PR after the feature is done, and must do so after the feature branch is already deleted — which makes the merge impossible unless the branch is recreated.

**What must stay stable:**
- Task PRs: `task-branch/{featureId}/{taskId}` → `feature/{id}` (impl repo and mgmt repo) — unchanged
- Workspace task PR auto-merge after impl PR merge — unchanged
- Executor and reviewer lifecycle — unchanged
- Handoff document format — unchanged

**Fixed assumptions:**
- Each feature has exactly one management repo feature branch: `feature/{id}`
- Each feature may reference 1..N impl repos (from task YAML `repo` fields)
- The management repo base branch is declared in `workspace.yaml` (not assumed to be `main`)

---

## 3. Options Considered

### Option A — Separate handoff branch; workspace feature PR auto-merged (chosen)

Introduce a dedicated `handoff/feature-{id}` branch. The Handoff Trigger opens a PR from this branch **into** `feature/{id}` (not into `main`). `feature/{id}` remains alive after the human merges the handoff PR. The Feature Done Watcher then writes done state to `feature/{id}` and auto-merges the workspace feature PR (`feature/{id}` → `main`) itself.

**Pros:**
- Feature branch stays alive until the orchestrator explicitly merges it
- Clean separation: handoff PR = review gate; workspace feature PR = merge gate
- All three bugs fixed in a single coherent model change
- `impl_feature_prs` naturally fits as the impl-repo counterpart

**Cons:**
- Requires storing `workspace_feature_pr_url` separately from `handoff_pr_url` (new status.yaml field)
- Lifecycle Manager step 4 (draft PR) must be repurposed: the draft PR it opens is now the **workspace feature PR**, not the handoff PR — requires renaming the recorded field

### Option B — Recreate feature branch after merge

Keep the current PR target (`feature/{id}` → `main`). After the merge and branch deletion, have the Feature Done Watcher (or Lifecycle Manager) recreate `feature/{id}` from `main`, write done state, then push again.

**Pros:** Minimal change to Handoff Trigger

**Cons:**
- Recreating a deleted branch changes its SHA; any pending task branches targeting the old `feature/{id}` tip will have diverged history
- Race window: if two poll cycles run between branch deletion and recreation, tasks can fail to claim
- Does not fix `impl_feature_prs` — still a separate gap

### Option C — Write done state to `main` after PR merge

After the PR is merged into `main`, read `status.yaml` directly from `main` and write done state there.

**Pros:** Avoids the branch-deletion problem entirely

**Cons:**
- Violates the no-direct-push-to-main rule — done state must arrive via PR
- Requires a new "post-merge write to main" code path with its own PR cycle
- Does not fix `impl_feature_prs`

**Decision:** Option A is chosen. It is the only option that resolves all three bugs without introducing new invariant violations.

---

## 4. Chosen Design

### 4.1 New `status.yaml` field: `workspace_feature_pr_url`

The Lifecycle Manager currently stores the draft PR URL in `handoff_pr_url`. With the redesign, that draft PR is the **workspace feature PR** (`feature/{id}` → `main`). It is stored in a new field: `workspace_feature_pr_url`.

`handoff_pr_url` is repurposed exclusively for the Handoff Trigger's new PR: `handoff/feature-{id}` → `feature/{id}`.

| Field | Written by | New value |
|---|---|---|
| `workspace_feature_pr_url` | Lifecycle Manager (step 4, on first creation) | URL of draft PR `feature/{id}` → `main` |
| `handoff_pr_url` | Handoff Trigger | URL of PR `handoff/feature-{id}` → `feature/{id}` |
| `impl_feature_prs` | Handoff Trigger | List of `{repo, url, status}` for each impl repo PR `feature/{id}` → `main` |

### 4.2 Lifecycle Manager (`lifecycle-manager.ts`)

**Change step 4:**
- Continue opening the draft PR: `feature/{id}` → `baseBranch` (no change to the PR itself)
- Record URL as `workspace_feature_pr_url` (previously `handoff_pr_url`)
- Read guard: skip if `workspace_feature_pr_url` is already set

**Remove step 5 (draft PR re-promotion):**
- The `in_handoff` re-promotion logic (lines 372–438) is deleted. The Handoff Trigger now creates a fresh, non-draft handoff PR directly. There is nothing to re-promote.

**Migration:** existing features whose `status.yaml` has `handoff_pr_url` set to a `feature/{id}` → `main` PR (the old semantics) must be migrated. The migration strategy is: if `handoff_pr_url` is set but `workspace_feature_pr_url` is absent, treat `handoff_pr_url` as `workspace_feature_pr_url` during the transition window. A one-time migration task writes the correct field.

### 4.3 Handoff Trigger (`handoff-trigger.ts`)

**Replace `promoteOrCreateFeaturePr` with three new steps:**

**Step 5a — Create `handoff/feature-{id}` branch from `feature/{id}`:**
```
git fetch origin
git checkout -B handoff/feature-{id} origin/feature/{id}
```

**Step 5b — Commit `handoff.md` to `handoff/feature-{id}`** (unchanged — same content, different branch):
```
git add handoffs/handoff.md
git commit -m "chore({featureId}): handoff document"
git push origin handoff/feature-{id}
```

**Step 5c — Open management-repo handoff PR:**
- `head`: `handoff/feature-{id}`
- `base`: `feature/{id}`
- Non-draft (ready for review immediately)
- Title: `feat({featureId}): handoff — {title}`
- Record URL as `status.yaml.handoff_pr_url`

**Step 5d — Open impl repo PRs:**
- For each impl repo referenced by any task YAML (`task.repo`), skip management-repo:
  - Open PR: `feature/{id}` → `baseBranch` (impl repo's `base_branch` from `workspace.yaml`)
  - Record as entry in `status.yaml.impl_feature_prs`: `{repo: repoId, url: prUrl, status: "open"}`

**status.yaml writes (step 6):**
- `handoff_pr_url` = management-repo handoff PR URL
- `impl_feature_prs` = list of impl repo PR entries
- `feature_status: in_handoff`
- `current_stage: handoff`
- (does NOT touch `workspace_feature_pr_url` — set by Lifecycle Manager)

### 4.4 Feature Done Watcher (`handle-feature-done.ts`)

**PR check (unchanged logic, corrected targets):**
- `handoff_pr_url` now points to `handoff/feature-{id}` → `feature/{id}` — this branch is never deleted by its merge, so `feature/{id}` remains alive
- `impl_feature_prs` is now populated — no more `impl_feature_prs_missing`

**When all PRs are merged — new write sequence:**

1. Checkout `feature/{id}` (which still exists):
   ```
   git fetch origin
   git checkout -B feature/{id} origin/feature/{id}
   ```

2. Write done state to `status.yaml` on the feature branch:
   ```yaml
   feature_status: done
   current_stage: done
   ```
   Commit + push to `feature/{id}`.

3. Auto-merge the workspace feature PR:
   - Read `workspace_feature_pr_url` from `status.yaml`
   - Check mergeability via GitHub REST API
   - If mergeable: call GitHub REST API `PUT /pulls/{n}/merge` (squash)
   - Emit `workspace_feature_pr_merged` or `workspace_feature_pr_merge_failed`

4. Emit `feature_done`.

**Backward compatibility:** if `workspace_feature_pr_url` is absent (pre-migration features), skip the auto-merge and emit `workspace_feature_pr_url_missing`. The human must merge manually as before.

### 4.5 Technical reference document (Goal 1 of product spec)

Produce a standalone `docs/features/handoff-pr-redesign/runtime-reference.md` document covering:

- Full orchestrator poll cycle step-by-step (what each function does, what state it reads/writes)
- Executor ABI: inputs (`ExecutorPortInput`), outputs (`result.json`), side-effects
- Per-process table: process name → reads → writes → skill or code
- Skill vs code boundary: which behaviors are TypeScript code and which are delegated to Claude

This document is independent of the code changes and can be produced in parallel.

---

## 5. Dependency Analysis

| Dependency | Status | Notes |
|---|---|---|
| GitHub REST API (PR create, merge, mergeability) | Existing — already used | No new API surfaces |
| `workspace_feature_pr_url` field in status.yaml | New — internal | Schema addition; backward-compatible (absent = fall back to legacy) |
| Impl repo local paths available | Required — env vars | `WORKFLOW_BACKEND_LOCAL_PATH` etc. must be set; Handoff Trigger must resolve via `resolveRepoLocalPath` |
| Impl repo `feature/{id}` branch exists | Required | Lifecycle Manager already creates it (Step 5 of runFeatureBranchLifecycle) — confirmed present before Handoff Trigger fires |
| GitHub token with PR create + merge permissions | Required | Already required; no new scopes |
| Migration of existing `handoff_pr_url` entries | Required for live features | Features already in `in_handoff` using old semantics need `workspace_feature_pr_url` backfilled |

**Unresolved:** if an impl repo has no `feature/{id}` branch (it was not created by the Lifecycle Manager, e.g. the repo was added to workspace.yaml after the feature started), the Handoff Trigger's impl PR creation will 422. The Handoff Trigger should check each impl repo's feature branch existence before opening the PR and emit a warning (non-fatal) if absent.

---

## 6. Parallelization / Blocking Analysis

```
T1: Produce runtime-reference.md (technical document)
  └── Can begin now — no blockers

T2: Lifecycle Manager — record workspace_feature_pr_url; remove step 5 re-promotion
  └── Can begin now — no blockers

T1 and T2 run in parallel.
  │
  T3: Handoff Trigger redesign — handoff branch + PR; impl repo PRs; populate impl_feature_prs
      └── BLOCKED on T2 (workspace_feature_pr_url field semantics must be frozen before Handoff
          Trigger drops its dependency on handoff_pr_url for the workspace feature PR)
      │
      T4: Feature Done Watcher redesign — write done state on feature branch; auto-merge workspace_feature_pr_url
          └── BLOCKED on T2 (needs workspace_feature_pr_url field to read for auto-merge)
          └── BLOCKED on T3 (needs impl_feature_prs populated to check correctly)
```

---

## 7. Repository Impact

| Repo | Files changed | Why |
|---|---|---|
| `workflow` | `runtime/orchestrator/src/feature-branch/lifecycle-manager.ts` | Record `workspace_feature_pr_url`; remove step 5 re-promotion |
| `workflow` | `runtime/orchestrator/src/handoff/handoff-trigger.ts` | Create handoff branch + PR; open impl repo PRs; populate `impl_feature_prs` |
| `workflow` | `runtime/orchestrator/src/poll/handle-feature-done.ts` | Write done state before auto-merging workspace feature PR |
| `management-repo` | `docs/features/handoff-pr-redesign/runtime-reference.md` | New technical reference document (T1) |

No changes to:
- Executor code (`executors/`)
- Reviewer or fix-agent dispatch
- Task PR flow
- Workspace task PR auto-merge
- Handoff document format
- `tasks.md` structure or task YAML schema

---

## 8. Validation and Release Impact

### Testing expectations

- **Unit tests** for each changed module: verify the Handoff Trigger opens the correct PR targets and populates `impl_feature_prs`; verify the Feature Done Watcher auto-merges `workspace_feature_pr_url` and writes done state to the feature branch (not to main).
- **Integration test** (if E2E test harness exists): run a full feature lifecycle with `idle_sleep_seconds: 0` (single-shot mode) and verify `feature_done` is emitted correctly with the feature branch still alive at the time of the done write.
- **Migration guard test**: feature with old-style `handoff_pr_url` (no `workspace_feature_pr_url`) must not regress — backward compat path emits `workspace_feature_pr_url_missing` and skips auto-merge cleanly.

### Rollout concerns

- Existing `in_handoff` features (live features) have `handoff_pr_url` pointing to `feature/{id}` → `main`. After deployment, their next poll cycle will check `handoff_pr_url` correctly (handoff PR is merged = the PR target was `feature/{id}` which means the feature branch is deleted) and fail the checkout. **Mitigation:** the backward compat path in the Feature Done Watcher (if `workspace_feature_pr_url` absent, skip auto-merge, emit warning) keeps these features from crashing; a human manually merges the workspace feature PR for pre-migration features.
- New features created after deployment use the new flow automatically (Lifecycle Manager writes `workspace_feature_pr_url` on first branch creation).
- No database migration needed — `status.yaml` changes are additive.

### Backward compatibility

- `status.yaml` fields are additive: `workspace_feature_pr_url` is new, `handoff_pr_url` is repurposed. Old features missing `workspace_feature_pr_url` fall back gracefully.
- The `handoff_pr_promoted` sentinel field is no longer written (step 5 removed from Lifecycle Manager). Old features that already have it are unaffected — it's ignored after this change.
