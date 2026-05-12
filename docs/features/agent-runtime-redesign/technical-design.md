# Technical Design — Agent Runtime Redesign

- Feature ID: `agent-runtime-redesign`
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

### Executor filesystem isolation (current gaps)

#### local-subprocess

`syncRepo()` in `bootstrap/bootstrap.ts` resets the management repo working tree to `baseBranch` on every poll cycle via `git checkout <baseBranch> && git reset --hard origin/<baseBranch>`. A `skipImplRepoPull` guard (`execInFlight` flag) protects impl repos from being reset while an executor subprocess is in flight — but **the management repo has no equivalent guard**. An executor writing task-branch commits to the management repo can have its working tree reset between commits.

`resolveRepoLocalPath()` reads operator-set env vars (`WORKFLOW_LOCAL_PATH`, `DIGITAL_FACTORY_UI_LOCAL_PATH`, etc.) to locate impl repos on disk. These paths are shared: two concurrent executors targeting the same impl repo receive the same directory.

#### local-docker

All containers share a single flat volume mount: `-v ${workspacesDir}:/workspace`. `TASK_REPO_PATH` is set to the orchestrator's host filesystem path (e.g., `/Users/matthew/workspace/workflow`). This path does not exist inside the container. `materializeRepo()` always falls through to a full clone and may write into a shared or incorrect location.

#### ABI gaps

| Gap | Current state |
|---|---|
| `HANDLE` | Passed as `-e HANDLE=${handle}` to docker containers only; absent from subprocess executor env; not in the formal ABI input table |
| `WORKSPACE_ROOT` | Day-1 single-container extra; not in formal ABI; set to orchestrator's host management-repo path — unusable inside containers without a matching volume mount |
| `TASK_REPO_PATH` | Set by orchestrator to its own host filesystem path; topology-dependent; incorrect inside docker containers |
| `MGMT_REPO_URL` | Not passed; executor has no way to clone the management repo independently |

---

## 2. Problem Framing

Three interconnected bugs in the current handoff flow:

**Bug 1 — Feature branch deleted before done state can be written.**
`handoff_pr_url` points to `feature/{id}` → `main`. When a human merges this PR, GitHub auto-deletes `feature/{id}`. The Feature Done Watcher's next poll tries `git checkout -B feature/{id} origin/feature/{id}` — this command fails because the remote ref no longer exists. The watcher emits `feature_done_check_failed` and the feature is stuck in `in_handoff` forever.

**Bug 2 — `impl_feature_prs` is never populated.**
No code path writes `impl_feature_prs`. The Handoff Trigger only opens/promotes the management repo PR. The Feature Done Watcher emits `impl_feature_prs_missing` every cycle and falls back to checking only `handoff_pr_url`.

**Bug 3 — No auto-merge of the workspace feature PR.**
The `feature_done` event is emitted but nothing acts on it. A human must manually merge the workspace feature PR after the feature is done, and must do so after the feature branch is already deleted — which makes the merge impossible unless the branch is recreated.

**Bug 4 — Executor filesystem isolation broken for docker; racy for subprocess.**
In `local-subprocess`, `syncRepo()` resets the management repo working tree every cycle with no guard, creating a race with executor writes. In `local-docker`, `TASK_REPO_PATH` is a host path that does not exist inside containers; `materializeRepo()` always clones into an unresolved or shared location. The ABI also lacks `HANDLE` (for subprocess), `MGMT_REPO_URL`, and a topology-agnostic base directory field, leaving executors unable to self-manage their filesystem isolation.

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

### Option D — Executor-owned repo materialisation; per-handle working directories (chosen for Bug 4)

Each executor is responsible for its own repo lifecycle. The orchestrator generates a handle UUID and passes a base working directory (`EXECUTOR_WORKDIR`). The executor derives all paths from it and materialises both the impl repo and management repo on startup.

**Pros:**
- Full filesystem isolation between concurrent executors — no shared paths, no orchestrator-side coordination required
- Orchestrator no longer maintains impl repo clones; `skipImplRepoPull` guard and `*_LOCAL_PATH` operator env vars are removed
- Topology-agnostic: same executor binary works for subprocess and docker without path-translation logic
- Management repo always on `main`, freshly pulled — executor reads current CLAUDE.md and skills on every invocation

**Cons:**
- Each executor clones the management repo on first cold invocation (warm on repeat at same `EXECUTOR_WORKDIR`)
- ABI version bump: add `HANDLE`, `EXECUTOR_WORKDIR`, `MGMT_REPO_URL`; remove `TASK_REPO_PATH`

**Decision:** Option D is chosen for Bug 4. It is independent of Option A — the two changes touch different files and can be implemented in parallel.

---

## 4. Chosen Design

### 4.0 Updated orchestrator main loop

For comparison with the current-state diagram in §1.

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
 │       syncRepo() × (workflow repo + N mgmt repos)   ← impl repos removed
 │       git fetch origin
 │       git checkout <baseBranch>
 │       git reset --hard origin/<baseBranch>
 │       ↳ skipImplRepoPull guard removed
 │
 │  [S-git] + [S-http]
 ├─ 2. runFeatureBranchLifecycle
 │       Guard: only runs for feature_status in
 │         [ready_for_implementation, in_implementation, in_handoff]
 │       git ls-remote, checkout, push  →  ensure feature/{id} on mgmt repo
 │       ↳ impl repo feature/{id} creation removed — executor handles it
 │       GitHub REST POST /pulls        →  open draft PR (first creation)  [S-http]
 │       Writes: status.yaml (feature_branch, feature_branch_base_sha,
 │                            workspace_feature_pr_url)   ← was handoff_pr_url
 │       ↳ step 5 in_handoff re-promotion removed
 │
 │  ╔═════════════════════════════════════════════════════════════════════════╗
 │  ║  dispatchBlock — skipped when executor pool is full                    ║
 │  ║  Steps try in order; first match dispatches [FF] and ends the block   ║
 │  ║                                                                        ║
 │  ║  [S-git] + [FF]                                                        ║
 │  ║  ├─ 3. Eligible-task dispatch  (status: ready)                         ║
 │  ║  │       findEligibleTasks  →  scan task YAMLs + tasks.md              ║
 │  ║  │       claimTask          →  git commit/push  [S-git]               ║
 │  ║  │       openWorkspacePr    →  GitHub REST POST /pulls  [S-http]      ║
 │  ║  │       fetchRagContext    →  HTTP MCP (optional)  [A-http]          ║
 │  ║  │       generateBriefing   →  in-process                             ║
 │  ║  │       adapter.submit({ HANDLE, EXECUTOR_WORKDIR, MGMT_REPO_URL,   ║
 │  ║  │                         TASK_REPO_URL, TASK_REPO_BRANCH,          ║
 │  ║  │                         TASK_BASE_BRANCH, ... })  [FF] ───────────┐║
 │  ║  │                                                                    │║
 │  ║  ├─ 4. Fix-agent dispatch  (status: change_requested)                 │║
 │  ║  │       findFixableTasks; claimFixTask; generateFixBriefing          │║
 │  ║  │       adapter.submit(same env contract)  [FF] ────────────────────┤║
 │  ║  │                                                                    │║
 │  ║  ├─ 5. In-review check                                                │║
 │  ║  │                                                                    │║
 │  ║  │    ├─ a. checkInReviewPrs  (rate-limited, GitHub GraphQL)  [A-http]│║
 │  ║  │    │       per in_review task: mergeable, draft, merged            │║
 │  ║  │    │       mergeable: false  →  claimRebase (mgmt repo commit/push) │║
 │  ║  │    │                           adapter.submit(kind:"rebase") [FF] ─┤║
 │  ║  │    │                           ↳ executor: git rebase + push to    │║
 │  ║  │    │                             impl repo (impl repo only)        │║
 │  ║  │    │                           reap loop: write result to task     │║
 │  ║  │    │                             YAML (mgmt repo) — resolved or    │║
 │  ║  │    │                             blocked; task stays in_review     │║
 │  ║  │    │                             until future cycle confirms       │║
 │  ║  │    │                             mergeable: true → 5b can fire     │║
 │  ║  │    │       merged: true  →  await handleMergedPrs() inline         │║
 │  ║  │    │                          (in-process orch. code, try/catch    │║
 │  ║  │    │                          surfaces errors; NOT a broker kind)  │║
 │  ║  │    │                                                               │║
 │  ║  │    └─ b. findReviewableTasks  (local YAML scan)                    │║
 │  ║  │           status: in_review or review_incomplete                   │║
 │  ║  │           pr.url set, last log ≠ reviewer_started                  │║
 │  ║  │           only reaches here if 5a found no conflicts or merges     │║
 │  ║  │           dispatchReviewer  →  git log entry/push  [S-git]        │║
 │  ║  │           adapter.submit(kind:"review")  [FF] ─────────────────────┤║
 │  ║  │                                                                    │║
 │  ║  └─ (nothing dispatched — cycle idles until next sleep)               │║
 │  ║                                                                        ║
 │  ║  Executor subprocesses (impl, review, review-fix, rebase) on startup:   ║
 │  ║    Phase 1: clone/pull mgmt repo at EXECUTOR_WORKDIR/mgmt (main, RO)  ║
 │  ║      → reads CLAUDE.md (copyWorkspaceClaude) + skills (setupGlobalSkills)
 │  ║    Phase 2: clone/reuse impl repo at EXECUTOR_WORKDIR/impl            ║
 │  ║      → create feature/{id} on origin if absent (TASK_BASE_BRANCH)     ║
 │  ║      → checkout task branch                                            ║
 │  ║  On ack(): adapter removes exec-{handle}/ directory                   ║
 │  ║  handleMergedPrs: awaited inline in 5a (in-process orch. code,        ║
 │  ║                   NOT a broker kind, NOT processed in reap loop).     ║
 │  ║                   await prevents next cycle's syncRepo from racing    ║
 │  ║                   with the merge-done cascade push.                   ║
 │  ╚═════════════════════════════════════════════════════════════════════════╝
 │
 │  [S-http] + [S-git]
 ├─ 6. Feature Done Watcher
 │       GitHub REST GET /pulls  →  handoff_pr_url         (handoff/{id} → feature/{id})
 │       GitHub REST GET /pulls  →  each impl_feature_prs  (feature/{id} → baseBranch)
 │       When ALL merged:
 │         git checkout -B feature/{id} origin/feature/{id}   ← still alive
 │         write status.yaml: feature_status: done, current_stage: done
 │         git commit + push to feature/{id}  [S-git]
 │         GitHub REST PUT /pulls/{n}/merge   →  auto-merge workspace_feature_pr_url
 │         emit feature_done
 │
 ├─ 7. Feature Review Daemon   (unchanged)
 │
 ├─ 8. State Invariant Checker  (unchanged)
 │
 │  [A-http] + [S-git] + [S-http]
 └─ 9. Reap Loop
         broker.listCompleted()  →  drain up to 10 results
         kind = "impl"        →  task done + ready cascade; impl PR if needed
         kind = "review"      →  writeDoneAndCascade → fireHandoffTrigger if all done
         kind = "review-fix"  →  emit review_dispatch_complete
         kind = "rebase"      →  on success: write conflict_state: resolved to task YAML (mgmt repo)
                             on failure: write status: blocked, blocked_reason: pr_conflict (mgmt repo)
         broker.ack() → adapter.ack() → rm -rf exec-{handle}/

       ◄──── executor results arrive here (impl, review, rebase, review-fix)

       Note: handleMergedPrs is NOT processed here. It runs in step 5a
             (awaited inline). Cascade: checkout task branch (mgmt repo);
             write status: done + cascade (mgmt repo); merge workspace PR
             (GitHub REST API); fireHandoffTrigger if all tasks done:
               git checkout -B handoff/feature-{id} origin/feature/{id}
               git commit handoff.md → push handoff/feature-{id}
               GitHub REST POST /pulls:
                 handoff/feature-{id} → feature/{id}  (mgmt, non-draft)
                 feature/{id} → baseBranch             (each impl repo, API only)
               Writes: status.yaml (in_handoff, handoff_pr_url,
                                    impl_feature_prs[...])

 └── sleep(idle_sleep_seconds) → repeat
```

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

### 4.4 PR poll merged into dispatch block

The separate PR poll step is eliminated. `checkInReviewPrs` moves into the dispatch block as step 5, after eligible-task and fix-agent dispatch (steps 3–4). The block still skips when the executor pool is full — a merged PR detected in a future cycle is fine since the GitHub state persists.

**Dispatch ordering within step 5:**
- **5a** `checkInReviewPrs` (GitHub GraphQL — runs every poll cycle; `idle_sleep_seconds` provides natural rate limiting): `mergeable: false` → `claimRebase` (mgmt repo commit/push) then `adapter.submit(kind: "rebase")` [FF]; `merged: true` → `await handleMergedPrs()` inline (in-process orchestrator code, wrapped in try/catch — see below). When either branch fires, `outcome = "ran_task"` so 5b is skipped this cycle.
- **5b** `findReviewableTasks` (local YAML scan — no GitHub API): `status: in_review` or `review_incomplete`, `pr.url` set, last log ≠ `reviewer_started` → `kind: "review"` [FF]. Runs only when `outcome !== "ran_task"`, i.e. 5a found no conflicts or merges this cycle, so a conflict is resolved before a reviewer is dispatched.

**`checkInReviewPrs`** — narrowed to pure read. Remove `WorkspacePrRecovery[]` feature-branch scanning entirely. Returns only `PrStatusResult[]` from a GitHub GraphQL batch call.

**`handleMergeConflicts`** — becomes `kind: "rebase"` executor dispatch. The executor materialises the impl repo at `EXECUTOR_WORKDIR/impl`, performs the rebase, and force-pushes the task branch to the impl repo. The reap loop handles the result (orchestrator code, mgmt repo only): write `conflict_state: resolved` to task YAML on success; write `status: blocked, blocked_reason: pr_conflict` on failure. This resolves the `⚠ impl repo path` problem — no orchestrator-side impl repo access needed.

**`handleMergedPrs`** — in-process orchestrator code (no Claude executor subprocess, no broker `kind`). When `checkInReviewPrs` detects `merged: true`, the call is `await`ed inline in step 5a within `dispatchBlock`, wrapped in `try/catch` so errors surface as `handle_merged_prs_error` events without throwing into the dispatch loop. The handler does mgmt repo + GitHub API work only: checkout task branch on mgmt repo, write `status: done` + auto-ready cascade, commit + push, merge workspace PR via GitHub REST API, call `fireHandoffTrigger` if all tasks done.

**Why `await` (not fire-and-forget):** the merge-done cascade writes to the mgmt repo task branch. If the call returned a Promise that the dispatch loop did not `await`, the next cycle's `syncRepo` could `git fetch` and reset the mgmt working tree before the cascade push completed, causing the newly-ready dependent tasks to be invisible to `findEligibleTasks` for an extra cycle. Awaiting blocks the dispatch loop for the duration (~1–2 s in practice, only triggered on cycles where a merged PR is detected) but eliminates the race. Errors are emitted, not thrown — a failure does not crash the orchestrator.

**`handleWorkspacePrRecoveries`** — removed. If a workspace PR fails to merge it is surfaced via the `merge-done` failure result and requires human resolution.

### 4.5 Feature Done Watcher (`handle-feature-done.ts`)

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

### 4.6 ABI changes (`runtime/abi/src/types.ts` + `abi-spec.md`)

| TypeScript field | Env var | Change | Notes |
|---|---|---|---|
| `handle` | `HANDLE` | **Add (formalise)** | Executor's unique invocation UUID. Already passed to docker containers; now also passed to subprocess executors. |
| `executorWorkdir` | `EXECUTOR_WORKDIR` | **Add (new)** | Base directory for this executor's working tree. Orchestrator sets to `${workspacesDir}/exec-{handle}` (subprocess) or `/workspace` (docker, fixed by per-handle volume mount). |
| `mgmtRepoUrl` | `MGMT_REPO_URL` | **Add (new)** | Management repo git URL. Executor clones read-only on `main` at `${EXECUTOR_WORKDIR}/mgmt`. |
| `taskRepoPath` | `TASK_REPO_PATH` | **Remove** | Executor derives as `${EXECUTOR_WORKDIR}/impl`. No longer set by orchestrator. |
| *(non-ABI)* | `WORKSPACE_ROOT` | **Remove from orchestrator env** | Executor derives as `${EXECUTOR_WORKDIR}/mgmt`. No longer set by orchestrator. |

**`HandleKind` addition:**

Add `"rebase"` to `HandleKind` in `types.ts`:
```typescript
export type HandleKind = "impl" | "review-fix" | "review" | "rebase";
```

The `"review-fix"` kind with `HandleSubkind = "rebase"` was an earlier design for rebase executors. It exists in the ABI but no code currently dispatches it; its reap loop handler only emits `review_dispatch_complete` with no YAML mutation. The new `"rebase"` kind replaces this intent with a correct handler (see §4.9 gap analysis).

### 4.7 Executor startup protocol (`runtime/executors/claude/src/index.ts`)

Replace the single-repo `materializeRepo(taskRepoUrl, taskRepoBranch, taskRepoPath, sshKeyPath)` with a two-phase startup. Both phases run before any task work.

**Phase 1 — Management repo (read-only, always `main`):**
```
mgmt_dir = ${EXECUTOR_WORKDIR}/mgmt
if mgmt_dir is a valid git repo with correct origin URL:
    git -C mgmt_dir fetch origin
    git -C mgmt_dir checkout main
    git -C mgmt_dir pull --ff-only origin main
else:
    rm -rf mgmt_dir
    git clone MGMT_REPO_URL mgmt_dir
    git -C mgmt_dir checkout main
WORKSPACE_ROOT = mgmt_dir   (process env; used by copyWorkspaceClaude, setupGlobalSkills)
```

**Phase 2 — Impl repo (existing protocol, corrected path):**
```
impl_dir = ${EXECUTOR_WORKDIR}/impl
TASK_REPO_PATH = impl_dir
(existing materializeRepo logic unchanged — reuses if origin URL matches, clones fresh otherwise)
```

Executor startup sequence: Phase 1 → Phase 2 → `copyWorkspaceClaude()` → `setupGlobalSkills()` → spawn Claude with `cwd: impl_dir`.

### 4.8 Orchestrator and adapter changes

**`runtime/orchestrator/src/bootstrap/bootstrap.ts`:**
- `syncRepo()` called only for the management repo in `pullWorkspaces`. All impl repo sync calls removed.
- `skipImplRepoPull` guard (`execInFlight` check) removed.

**`runtime/orchestrator/src/main.ts` + `config/workspace-config.ts`:**
- `resolveRepoLocalPath()` removed from executor dispatch path. Operator env vars `WORKFLOW_LOCAL_PATH`, `DIGITAL_FACTORY_UI_LOCAL_PATH`, etc. are no longer required.
- `buildAndSubmitExecutor` passes `executorWorkdir`, `handle`, and `mgmtRepoUrl` in place of `taskRepoPath` and `WORKSPACE_ROOT`.
- `mgmtRepoUrl` resolved from the management-repo entry in `workspace.yaml` (`github:` field).
- PR poll step: `handleMergeConflicts` replaced by a `kind: "rebase"` executor dispatch via `adapter.submit()`. The `resolveImplRepoRoot` parameter is removed — executor derives the impl path from `EXECUTOR_WORKDIR`.
- PR poll step: `handleMergedPrs` deferred to run async (orchestrator code, not an executor subprocess).
- PR poll step: `handleWorkspacePrRecoveries` removed entirely.

**`runtime/orchestrator/src/poll/reap-loop.ts`:**
- Add handler for `kind === "rebase"`: on `terminal_status: "in_review"` write `conflict_state: resolved` to task YAML; on `terminal_status: "blocked"` write `status: blocked, blocked_reason: pr_conflict`.
- `kind === "review-fix"` handler left in place (emits `review_dispatch_complete`) — it is dead code but removal is out of scope.

**`runtime/orchestrator/src/pr-response/auto-rebase.ts`:**
- `handleMergeConflicts` removed from the inline PR poll step. Its logic moves to the `kind: "rebase"` executor (which runs as a subprocess at `EXECUTOR_WORKDIR`).
- `autoRebase` function may be repurposed as the executor entrypoint or removed if the executor implements the logic directly.

**`runtime/orchestrator/src/adapters/executor/subprocess.ts`:**
- Pass `HANDLE` env var to subprocess (currently absent).
- Pass `EXECUTOR_WORKDIR = ${workspacesDir}/exec-{handle}`.
- Pass `MGMT_REPO_URL`.
- Remove `TASK_REPO_PATH` and `WORKSPACE_ROOT` from subprocess env.
- `ack()`: add `rm -rf ${workspacesDir}/exec-{handle}` after result is processed.

**`runtime/orchestrator/src/adapters/executor/docker-run.ts`:**
- Change volume mount from `-v ${workspacesDir}:/workspace` (flat, shared) to `-v ${workspacesDir}/exec-{handle}:/workspace` (per-handle, isolated).
- Pass `EXECUTOR_WORKDIR=/workspace` (fixed container-internal path).
- Pass `MGMT_REPO_URL`.
- Remove `TASK_REPO_PATH` and `WORKSPACE_ROOT` from container env.
- `ack()`: add `rm -rf ${workspacesDir}/exec-{handle}` host-path cleanup (runs after `docker rm`).

### 4.9 Executor result contracts

Maps what each executor kind writes to `result.json` against what the reap loop expects. Used to verify the dispatch↔reap round-trip is consistent and to identify gaps introduced by this feature.

```
─────────────────────────────────────────────────────────────────────────────────────
WHAT EXECUTORS WRITE TO result.json
─────────────────────────────────────────────────────────────────────────────────────

kind: "impl"
  Dispatched by: buildAndSubmitExecutor (status:ready tasks + status:change_requested fix tasks)
  ExecutorResult {
    terminal_status : "in_review"    ← work done; PR opened; awaiting review
                    | "blocked"      ← stuck; needs human; partial commits preserved
                    | "failed"       ← executor crash; treated as blocked by reap loop
    pr_url?         : string         ← impl PR URL opened by executor (if commits pushed)
    blocked_reason? : string         ← required when terminal_status = "blocked"
    token_usage?    : { input, output, model }
    cost_usd?       : number
    handover_path?  : string         ← path to handover.md for next executor's briefing
  }

kind: "review"
  Dispatched by: dispatchReviewer (handleKind: "review" on SubProcessAdapter)
  ReviewerResult {
    terminal_status : "passed"           ← review passed; task can be marked done
                    | "change_requested" ← reviewer posted REQUEST_CHANGES on PR
                    | "escalate"         ← reviewer cannot proceed; human needed
                    | <other / absent>   ← incomplete (max-turns, crash, no result.json)
    verdict         : same as terminal_status
    confidence      : number
    notes           : string
    review_url?     : string             ← GitHub review URL
    self_review_skipped? : boolean       ← true when GitHub blocked self-review (HTTP 422)
  }

kind: "review-fix"   subkind: "rebase" | "respond"
  Dispatched by: NOTHING — no code currently dispatches review-fix executors
  ExecutorResult { terminal_status: any }
  NOTE: defined in ABI + handled in reap loop but dispatch path is dead code

kind: "rebase"   [NEW — proposed by this feature; does not exist in HandleKind today]
  Dispatched by: step 5a (checkInReviewPrs detects mergeable:false) after claimRebase
  ExecutorResult {
    terminal_status : "in_review"  ← rebase + force-push succeeded; task stays in_review;
                                     PR will show mergeable:true in next cycle
                    | "blocked"    ← unresolvable conflict; conflict markers committed to
                                     impl branch; human must resolve manually
    blocked_reason? : "pr_conflict"   ← set when terminal_status = "blocked"
  }

─────────────────────────────────────────────────────────────────────────────────────
WHAT THE REAP LOOP DOES ON EACH KIND
─────────────────────────────────────────────────────────────────────────────────────

kind: "impl"   →   dispatchExecutorResult
  "in_review"
    → task YAML: status=in_review, pr.url recorded
    → promote impl PR from draft → ready-for-review (GitHub GraphQL)
    (max-turns guard: if blocked_reason starts with "max_turns" and retry count < MAX,
     reset to status:ready instead of blocked)
  "blocked" / "failed"
    → task YAML: status=blocked, blocked_reason recorded, pr.url recorded if present

kind: "review"   →   dispatchReviewResult
  "passed"
    → writeDoneAndCascade: task YAML status=done; auto-ready cascade for dependents
    → if allTasksDone: fireHandoffTrigger
  "change_requested"
    → task YAML: status=change_requested
    → demote impl PR back to draft (GitHub API)
  "escalate"
    → handleEscalation: task YAML status=blocked; post Slack alert
  <other> (incomplete / max-turns)
    → if review_blocked_count < MAX_REVIEW_INCOMPLETES:
        task YAML: status=review_incomplete, log: review_blocked
      else:
        handleEscalation → blocked

kind: "review-fix"   →   emit review_dispatch_complete only (no YAML mutation)
  NOTE: handler exists but dispatch path is dead — no executor ever produces this kind

kind: "rebase"   [NEW — handler must be added to reap-loop.ts in T6]
  "in_review" (rebase success)
    → task YAML: conflict_state=resolved (mgmt repo)
    → task stays status=in_review; reviewer fires when next cycle confirms mergeable:true
  "blocked" (unresolvable conflict)
    → task YAML: status=blocked, blocked_reason=pr_conflict (mgmt repo)

merge-done   [in-process orchestrator code — NOT a broker executor kind]
  → NOT processed via broker.listCompleted; NOT fire-and-forget
  → when checkInReviewPrs detects merged:true, handleMergedPrs is AWAITED inline
    in step 5a within dispatchBlock (wrapped in try/catch — errors emit as
    handle_merged_prs_error without throwing into the dispatch loop):
      checkout task branch (mgmt repo); write status:done + cascade (mgmt repo);
      merge workspace PR (GitHub REST API);
      if allTasksDone: fireHandoffTrigger
  → await is required to prevent the next cycle's syncRepo from racing with the
    cascade push (which would hide newly auto-readied tasks for an extra cycle).

─────────────────────────────────────────────────────────────────────────────────────
GAP ANALYSIS
─────────────────────────────────────────────────────────────────────────────────────

Gap 1 — kind:"rebase" not in HandleKind
  Current: autoRebase runs SYNCHRONOUSLY inline in the PR poll step (not an executor).
           It needs implRepoRoot via resolveRepoLocalPath — breaks under executor isolation.
  Fix (T5): add "rebase" to HandleKind in abi/src/types.ts
  Fix (T6): add kind:"rebase" result handler to reap-loop.ts;
            convert handleMergeConflicts to dispatch kind:"rebase" via adapter.submit()

Gap 2 — kind:"review-fix" is dead code
  Current: HandleKind and reap-loop handler exist but no dispatch code uses them.
           HandleSubkind "rebase" was an earlier approach for the auto-rebase executor.
  Fix: none required for this feature; may be removed or repurposed in a future task

Gap 3 — handleMergedPrs placement in the dispatch loop
  Current (pre-T6): called inline in the post-dispatch PR poll step and awaited.
  Initial T6 plan: defer to fire-and-forget (no await) after checkInReviewPrs returns.
  Shipped in T6: kept awaited, but moved inside dispatchBlock (step 5a). The
    fire-and-forget variant was tried and revealed a race: the next cycle's
    syncRepo would reset the mgmt working tree before the cascade push completed,
    hiding newly auto-readied dependent tasks for an extra cycle. await is the
    correct semantic here even though it blocks the dispatch loop for ~1–2 s on
    cycles that detect a merged PR. Wrapped in try/catch so errors emit as
    handle_merged_prs_error without throwing.
```

### 4.10 Technical reference document (Goal 1 of product spec)

Produce a standalone `docs/features/agent-runtime-redesign/runtime-reference.md` document covering:

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
| Impl repo local paths available | **Removed** | Orchestrator no longer accesses impl repos directly. Handoff Trigger opens impl repo PRs via GitHub REST API only. `resolveRepoLocalPath()` removed from all orchestrator paths. |
| Impl repo `feature/{id}` branch exists | Required — created by executors | Executors create `feature/{id}` on origin during Phase 2 startup (`TASK_BASE_BRANCH`). By the time all tasks are `done`, each referenced impl repo already has the feature branch. The Handoff Trigger opens the impl repo PR against this branch via GitHub REST API. |
| GitHub token with PR create + merge permissions | Required | Already required; no new scopes |
| Migration of existing `handoff_pr_url` entries | Required for live features | Features already in `in_handoff` using old semantics need `workspace_feature_pr_url` backfilled |
| `EXECUTOR_WORKDIR` per-handle directories | New — internal | Created by adapters at dispatch time; cleaned up on `ack()`. No operator configuration needed. |
| `MGMT_REPO_URL` in ABI | New — internal | Resolved from `workspace.yaml` management-repo `github:` field; no new operator configuration needed. |
| Operator `*_LOCAL_PATH` env vars | **Removed** | `WORKFLOW_LOCAL_PATH`, `DIGITAL_FACTORY_UI_LOCAL_PATH`, etc. no longer required for executor dispatch. |

**Unresolved:** if an impl repo has no `feature/{id}` branch (it was not created by the Lifecycle Manager, e.g. the repo was added to workspace.yaml after the feature started), the Handoff Trigger's impl PR creation will 422. The Handoff Trigger should check each impl repo's feature branch existence before opening the PR and emit a warning (non-fatal) if absent.

---

## 6. Parallelization / Blocking Analysis

```
T1: Produce runtime-reference.md (management-repo)
  └── Can begin now — no blockers

T2: Lifecycle Manager — record workspace_feature_pr_url; remove step 5 re-promotion (workflow)
  └── Can begin now — no blockers

T5: ABI + executor startup — formalise HANDLE; add EXECUTOR_WORKDIR, MGMT_REPO_URL;
    add "rebase" to HandleKind; two-phase startup; remove TASK_REPO_PATH (workflow)
  └── Can begin now — no blockers

T1, T2, and T5 run in parallel.
  │
  T3: Handoff Trigger redesign — handoff branch + PR; impl repo PRs; impl_feature_prs (workflow)
      └── BLOCKED on T2 (workspace_feature_pr_url semantics must be frozen before Handoff
          Trigger drops its dependency on handoff_pr_url for the workspace feature PR)

  T5 may still be in progress while T3 runs — they are independent.
      │
      T4: Feature Done Watcher redesign — write done state on feature branch;
          auto-merge workspace_feature_pr_url (workflow)
          └── BLOCKED on T2 (needs workspace_feature_pr_url field to read for auto-merge)
          └── BLOCKED on T3 (needs impl_feature_prs populated to check correctly)
          (T4 does not depend on T5 or T6)

      T6: Orchestrator dispatch + adapters — per-handle EXECUTOR_WORKDIR; SubprocessAdapter +
          DockerRunAdapter isolation; remove impl repo syncing; ack() cleanup;
          convert handleMergeConflicts → kind:"rebase" executor dispatch;
          add kind:"rebase" handler to reap-loop.ts;
          defer handleMergedPrs as async orchestrator code;
          remove handleWorkspacePrRecoveries (workflow)
          └── BLOCKED on T5 (ABI types + HandleKind must be defined before orchestrator uses them)
          └── BLOCKED on T3 (reap loop merge-done path calls fireHandoffTrigger — must use T3's updated version)

      T4 and T6 run in parallel (different files; no mutual dependency).
```

---

## 7. Repository Impact

| Repo | Files changed | Why |
|---|---|---|
| `workflow` | `runtime/orchestrator/src/feature-branch/lifecycle-manager.ts` | Record `workspace_feature_pr_url`; remove step 5 re-promotion |
| `workflow` | `runtime/orchestrator/src/handoff/handoff-trigger.ts` | Create handoff branch + PR; open impl repo PRs; populate `impl_feature_prs` |
| `workflow` | `runtime/orchestrator/src/poll/handle-feature-done.ts` | Write done state before auto-merging workspace feature PR |
| `management-repo` | `docs/features/agent-runtime-redesign/runtime-reference.md` | New technical reference document (T1) |

| `workflow` | `runtime/abi/src/types.ts`, `runtime/abi/docs/abi-spec.md` | Add `HANDLE`, `EXECUTOR_WORKDIR`, `MGMT_REPO_URL`; add `"rebase"` to `HandleKind`; remove `TASK_REPO_PATH` (T5) |
| `workflow` | `runtime/executors/claude/src/index.ts` | Two-phase startup; derive impl + mgmt paths from `EXECUTOR_WORKDIR` (T5) |
| `workflow` | `runtime/orchestrator/src/bootstrap/bootstrap.ts` | Remove impl repo `syncRepo()` calls; remove `skipImplRepoPull` guard (T6) |
| `workflow` | `runtime/orchestrator/src/adapters/executor/subprocess.ts` | Pass `HANDLE` + `EXECUTOR_WORKDIR` + `MGMT_REPO_URL`; `ack()` directory cleanup (T6) |
| `workflow` | `runtime/orchestrator/src/adapters/executor/docker-run.ts` | Per-handle volume mount; pass `EXECUTOR_WORKDIR=/workspace`; `ack()` host cleanup (T6) |
| `workflow` | `runtime/orchestrator/src/main.ts`, `config/workspace-config.ts` | Remove `resolveRepoLocalPath` from dispatch; pass `EXECUTOR_WORKDIR` + `MGMT_REPO_URL`; convert handleMergeConflicts to kind:"rebase" dispatch; defer handleMergedPrs; remove handleWorkspacePrRecoveries (T6) |
| `workflow` | `runtime/orchestrator/src/poll/reap-loop.ts` | Add `kind: "rebase"` result handler (T6) |
| `workflow` | `runtime/orchestrator/src/pr-response/auto-rebase.ts` | Remove from inline PR poll path; logic moves to kind:"rebase" executor (T6) |

No changes to:
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
- **Unit tests for executor startup (T5):** verify Phase 1 (management repo clone/pull on `main`) runs before Phase 2 (impl repo materialisation); verify `WORKSPACE_ROOT` and `TASK_REPO_PATH` are correctly derived from `EXECUTOR_WORKDIR`.
- **Unit tests for adapters (T6):** SubprocessAdapter passes `HANDLE` + `EXECUTOR_WORKDIR`; DockerRunAdapter mounts `${workspacesDir}/exec-{handle}` not the flat `workspacesDir`; `ack()` removes the `exec-{handle}` directory.
- **Isolation test (T6):** spawn two concurrent executors targeting the same impl repo; verify each operates in its own `exec-{handle}` directory with no shared state.

### Rollout concerns

- Existing `in_handoff` features (live features) have `handoff_pr_url` pointing to `feature/{id}` → `main`. After deployment, their next poll cycle will check `handoff_pr_url` correctly (handoff PR is merged = the PR target was `feature/{id}` which means the feature branch is deleted) and fail the checkout. **Mitigation:** the backward compat path in the Feature Done Watcher (if `workspace_feature_pr_url` absent, skip auto-merge, emit warning) keeps these features from crashing; a human manually merges the workspace feature PR for pre-migration features.
- New features created after deployment use the new flow automatically (Lifecycle Manager writes `workspace_feature_pr_url` on first branch creation).
- No database migration needed — `status.yaml` changes are additive.

### Backward compatibility

- `status.yaml` fields are additive: `workspace_feature_pr_url` is new, `handoff_pr_url` is repurposed. Old features missing `workspace_feature_pr_url` fall back gracefully.
- The `handoff_pr_promoted` sentinel field is no longer written (step 5 removed from Lifecycle Manager). Old features that already have it are unaffected — it's ignored after this change.
