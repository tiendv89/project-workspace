# Orchestrator Runtime Reference

> **Scope:** Describes the runtime **as it exists today** — before `agent-runtime-redesign` lands. This is the reference baseline for all tasks in this feature. For the redesign see `technical-design.md`.
>
> Source cross-checked against: `runtime/orchestrator/src/main.ts`, `lifecycle-manager.ts`, `handoff-trigger.ts`, `handle-feature-done.ts`, `auto-rebase.ts`, `check-in-review-prs.ts`, `dispatch-reviewer.ts`, `side-effects/dispatch.ts`, `side-effects/dispatch-review-result.ts`, `poll/reap-loop.ts`, `runtime/abi/src/types.ts`, `runtime/abi/docs/abi-spec.md`.

---

## 1. Poll Cycle

`main.ts → runOneCycle()` — all steps run **sequentially** within a cycle. The cycle sleeps `idle_sleep_seconds` between runs.

```
Legend
  [S-git]  execSync / spawnSync git — blocks the Node.js event loop
  [S-http] spawnSync curl / curlJson — blocks event loop
  [A-http] fetch() / awaited call — yields to event loop
  [FF]     adapter.submit() — fire-and-forget; result arrives in a FUTURE cycle
```

```
sleep(idle_sleep_seconds)
      │
      ▼
runOneCycle()
│
│  [S-git]
├─ 1. pullWorkspaces
│       syncRepo() × (workflow repo + N mgmt repos + N impl repos)
│         git fetch origin
│         git checkout <baseBranch>
│         git reset --hard origin/<baseBranch>
│       ↳ impl repos skipped when execInFlight=true (skipImplRepoPull guard)
│
│  [S-git] + [S-http]
├─ 2. runFeatureBranchLifecycle   (each feature with eligible feature_status)
│       eligible: ready_for_implementation | in_implementation | in_handoff
│       [management repo]
│         ensureFeatureBranch: git ls-remote, checkout -B, push  →  feature/{id}
│         step 3: write feature_branch + feature_branch_base_sha to status.yaml (once)
│         step 4: GitHub REST POST /pulls  →  open draft PR (feature/{id}→main) [S-http]
│                 record URL as status.yaml.handoff_pr_url (idempotent)
│         step 5: if in_handoff + handoff_pr_url is still draft  →  markPrReadyForReview [S-http]
│                 commit handoff_pr_promoted=true to feature branch; push with --force-with-lease
│       [impl repos] (each unique repo ID in feature task YAMLs)
│         ensureImplRepoFeatureBranch: git ls-remote, checkout -B, push  →  feature/{id}
│
│  ╔═══════════════════════════════════════════════════════════════════════╗
│  ║  dispatchBlock — SKIPPED ENTIRELY when executor pool is full         ║
│  ║  (local-subprocess: max 1 in-flight; local-docker: configurable)    ║
│  ║  Steps try in order; first match submits [FF] and exits the block   ║
│  ║                                                                      ║
│  ║  [S-git] + [S-http] + [FF]                                          ║
│  ║  ├─ 3. Eligible-task dispatch   (status: ready)                     ║
│  ║  │       findEligibleTasks  →  scan task YAMLs on filesystem        ║
│  ║  │       claimTask          →  git commit/push (status→in_progress) ║
│  ║  │       openWorkspacePr    →  GitHub REST POST /pulls  [S-http]   ║
│  ║  │       fetchRagContext    →  HTTP MCP call (optional)  [A-http]  ║
│  ║  │       generateBriefing   →  in-process template                 ║
│  ║  │       adapter.submit()   →  [FF] ─────────────────────────────┐ ║
│  ║  │                                                                │ ║
│  ║  ├─ 4. Fix-agent dispatch   (status: change_requested)            │ ║
│  ║  │       findFixableTasks; claimFixTask; generateFixBriefing      │ ║
│  ║  │       adapter.submit()   →  [FF] ─────────────────────────────┤ ║
│  ║  │                                                                │ ║
│  ║  └─ 5. Reviewer dispatch   (status: in_review or review_incomplete)│ ║
│  ║          findReviewableTasks  →  scan task YAMLs                  │ ║
│  ║          dispatchReviewer    →  git log entry/push  [S-git]      │ ║
│  ║          adapter.submit()    →  [FF] ─────────────────────────────┘ ║
│  ║                                                                      ║
│  ╚═══════════════════════════════════════════════════════════════════════╝
│
│  (rate-limited by pr_poll_interval_seconds; skipped if subprocess in-flight)
│  [S-http] + [S-git]
├─ 6. PR poll
│       checkInReviewPrs    →  GitHub GraphQL batch call for in_review tasks  [S-http]
│       handleMergeConflicts →  for each mergeable:false task:
│                               autoRebase() inline (git rebase + force-push)  [S-git]
│                               Claude CLI subprocess for YAML conflict resolution (awaited)
│       handleMergedPrs      →  for each merged:true task:
│                               git checkout task branch; write done + cascade  [S-git]
│                               GitHub REST PUT /pulls/{n}/merge  [S-http]
│                               if allTasksDone → fireHandoffTrigger (see §3.9)
│       handleWorkspacePrRecoveries →  GitHub REST retry merge for recovered tasks  [S-http]
│
│  [S-http] + [S-git]
├─ 7. Feature Done Watcher   (handleFeatureDone)
│       for each feature with feature_status=in_handoff:
│         read status.yaml from origin/feature/{id} (git show) or local FS
│         check impl_feature_prs: if absent → emit impl_feature_prs_missing
│         GitHub REST GET /pulls → handoff_pr_url merge state  [S-http]
│         GitHub REST GET /pulls → each impl_feature_prs entry  [S-http]
│         all merged → git checkout feature/{id} (BUG: fails after PR merge)
│                      write feature_status:done + push  [S-git]
│                      emit feature_done
│
│  (every FEATURE_REVIEW_INTERVAL cycles — default 20)
│  [S-git] + [S-http] + optional [FF]
├─ 8. Feature Review Daemon   (runFeatureReviewCycle)
│       git merge-base; GitHub drift check
│       git rebase for task-level drift
│       Claude subprocess (reviewer) for feature-level conflict  [FF]
│
│  (every STATE_INVARIANT_CHECK_INTERVAL cycles — default 5)
│  [S-git]
├─ 9. State Invariant Checker   (runStateInvariantCheck)
│       git show origin/<branch>:<path>; parseYaml; sanity checks
│
│  [A-http] + [S-git] + [S-http]
└─ 10. Reap Loop   (runReapLoop)
        broker.listCompleted()  →  drain up to 10 completed executors
        route by handle.kind:
          "impl"       →  dispatchExecutorResult (see §3.12)
          "review"     →  dispatchReviewResult (see §3.13)
          "review-fix" →  emit review_dispatch_complete only (dead dispatch path)
        broker.ack() / broker.nack()

      ◄──── executor results posted here by subprocesses from steps 3–5

└── sleep(idle_sleep_seconds) → repeat
```

---

## 2. Executor ABI (current)

### 2.1 Inputs (env vars passed by orchestrator)

From `runtime/abi/src/types.ts` and `runtime/abi/docs/abi-spec.md`:

| TypeScript field | Env var | Required | Notes |
|---|---|---|---|
| `taskId` | `TASK_ID` | yes | |
| `featureId` | `FEATURE_ID` | yes | |
| `workspaceId` | `WORKSPACE_ID` | yes | |
| `taskRepoUrl` | `TASK_REPO_URL` | yes | Git URL of the impl repo |
| `taskRepoBranch` | `TASK_REPO_BRANCH` | yes | Task branch (e.g. `task-branch/{featureId}/{taskId}`) |
| `taskBaseBranch` | `TASK_BASE_BRANCH` | yes | PR base: `feature/{id}` or repo base branch |
| `taskRepoPath` | `TASK_REPO_PATH` | yes | Local path where executor materialises the impl repo |
| `briefingPath` | `BRIEFING_PATH` | yes | |
| `resultPath` | `RESULT_PATH` | yes | |
| `budgetTokens` | `BUDGET_TOKENS` | no | |
| `sshKeyPath` | `SSH_KEY_PATH` | yes | |
| `githubToken` | `GITHUB_TOKEN` | yes | |
| *(non-ABI)* | `HANDLE` | docker only | Executor UUID; passed to docker containers, absent from subprocess env |
| *(non-ABI)* | `WORKSPACE_ROOT` | extra | Host path to management repo; unusable inside docker containers |

**Note:** `HANDLE` is absent from the formal ABI table but passed to docker containers via `-e HANDLE=`. Subprocess executors do not receive it.

### 2.2 Outputs (`result.json`)

`ExecutorResult` (for `kind: "impl"` and `kind: "review-fix"`):

```typescript
{
  terminal_status : "in_review" | "blocked" | "failed"
  pr_url?         : string        // impl PR URL; present if commits were pushed
  blocked_reason? : string        // required when terminal_status = "blocked"
  blocked_suggestion? : string
  token_usage?    : { input: number; output: number; model?: string }
  cost_usd?       : number
  handover_path?  : string        // path to handover.md (Layer 1 recovery)
}
```

`ReviewerResult` (for `kind: "review"`):

```typescript
{
  terminal_status : "passed" | "change_requested" | "escalate" | <other/absent>
  verdict         : string
  confidence      : number
  notes           : string
  review_url?     : string
  self_review_skipped? : boolean
}
```

### 2.3 HandleKind (current)

```typescript
type HandleKind = "impl" | "review-fix" | "review";
// "rebase" does NOT exist today — added by T5
type HandleSubkind = "rebase" | "respond";  // subkinds of review-fix; no active dispatch
```

### 2.4 Executor side effects

The executor **owns**:
- Materialising `TASK_REPO_PATH` (clone or fetch+checkout+pull)
- Making code changes in `TASK_REPO_PATH`
- `git commit + push` to `TASK_REPO_BRANCH`
- Opening the **implementation-repo PR** (head: task branch → base: `TASK_BASE_BRANCH`)
- Writing `result.json` to `RESULT_PATH`

The executor **never**:
- Reads or writes the management repo
- Opens or closes workspace/management-repo PRs
- Writes task YAML files
- Applies the auto-ready rule

### 2.5 Materialization protocol (executor startup)

```
if TASK_REPO_PATH exists and is a git repo:
    origin = git remote get-url origin
    if origin == TASK_REPO_URL:
        git fetch origin
        git checkout TASK_REPO_BRANCH
        git pull --ff-only origin TASK_REPO_BRANCH
    else:
        rm -rf TASK_REPO_PATH
        git clone TASK_REPO_URL TASK_REPO_PATH
        git checkout TASK_REPO_BRANCH
else:
    git clone TASK_REPO_URL TASK_REPO_PATH
    git checkout TASK_REPO_BRANCH
```

After materialization: `copyWorkspaceClaude()` → `setupGlobalSkills()` → spawn Claude with `cwd = TASK_REPO_PATH`.

### 2.6 Termination safety

Two-layer mechanism (see `abi-spec.md` §Termination safety):

- **Layer 1 (always-on):** `try/finally` in `executors/claude/src/index.ts` calls `runRecovery()` on any exit. Recovery commits dirty tree, pushes, opens draft PR, writes `handover.md`, writes `result.json` with `terminal_status: "blocked"`.
- **Layer 2 (best-effort):** Briefing instructs Claude to checkpoint with `wip(...)` commits and write `handover.md` before max-turns.
- **Layer 3 (orchestrator):** On re-claim, `agent-context.ts` prepends `handover.md` to the new briefing.

---

## 3. Per-Process Reference

### 3.1 Feature Branch Lifecycle Manager

**File:** `runtime/orchestrator/src/feature-branch/lifecycle-manager.ts`
**Called from:** `runOneCycle()` step 2, once per feature with eligible `feature_status`
**Skill vs code:** pure TypeScript — no Claude delegation

**Reads:**
- `git ls-remote origin refs/heads/feature/{id}` — branch existence
- `git show origin/{baseBranch}:docs/features/{id}/status.yaml` — current status fields
- `git show origin/{baseBranch}:docs/features/{id}/tasks/*.yaml` — task `repo` fields (for impl repo IDs)
- `workspace.yaml` — repo IDs, base branches, management repo ID

**Writes:**
| Step | What | Where |
|---|---|---|
| 3 | `feature_branch` + `feature_branch_base_sha` (once, never overwritten) | `status.yaml` on `feature/{id}` |
| 4 | Draft PR (`feature/{id}` → `main`); URL recorded as `handoff_pr_url` | GitHub + `status.yaml` on `feature/{id}` |
| 5 | Promotes `handoff_pr_url` PR from draft to ready-for-review when `feature_status=in_handoff`; writes `handoff_pr_promoted=true` | GitHub GraphQL + `status.yaml` on `feature/{id}` (CAS push) |
| impl repos | `feature/{id}` branch on each impl repo | impl repo origin |

**Events emitted:** `feature_branch_created`, `feature_branch_synced`, `feature_branch_status_updated`, `draft_pr_opened`, `draft_pr_skipped`, `handoff_pr_promoted`, `impl_feature_branch_created`, `impl_feature_branch_synced`, `feature_branch_lifecycle_error`

---

### 3.2 Eligible-Task Dispatch (Claim)

**Files:** `claim/claim-task.ts`, `main.ts`
**Called from:** `runOneCycle()` dispatch block step 3
**Skill vs code:** orchestrator handles claim; Claude subprocess does implementation

**Reads:**
- Task YAMLs from filesystem (on `baseBranch`): `status`, `depends_on`, `repo`
- `tasks.md` for skill slugs
- `workspace.yaml` for repo URLs and base branches

**Writes (orchestrator):**
- `task.status = "in_progress"`, `log.claimed`, `workspace_pr.url` in task YAML on task branch — git commit + push (claim commit — first-push-wins)
- Workspace PR: `task-branch/{featureId}/{taskId}` → `feature/{id}` via GitHub REST API

**Writes (executor subprocess — arrives via reap loop):**
- Code changes in impl repo; `git push`; impl PR opened; `result.json`

---

### 3.3 Fix-Agent Dispatch

**Files:** `main.ts`, claim helpers
**Called from:** `runOneCycle()` dispatch block step 4 (only if step 3 found nothing)
**Skill vs code:** orchestrator handles claim; Claude subprocess does fix

**Reads:** Task YAMLs with `status: change_requested`

**Writes (orchestrator):**
- `task.status = "in_progress"`, `log.fix_started` in task YAML — commit + push (first-push-wins, same claim protocol as step 3)

**Writes (executor subprocess — arrives via reap loop):**
- Code changes + push; updated impl PR; `result.json`

---

### 3.4 Reviewer Dispatch

**File:** `runtime/orchestrator/src/pr-response/dispatch-reviewer.ts`
**Called from:** `runOneCycle()` dispatch block step 5
**Skill vs code:** orchestrator handles claim commit; Claude subprocess does review

**Reads:**
- Task YAMLs: `status in_review | review_incomplete`, `pr.url` set, last log entry ≠ `reviewer_started`
- Cycle count guard: `countReviewCycles(task)` — stops at `maxReviewCycles` (default 3)

**Writes (orchestrator — claim):**
- `task.status = "in_review"` (reset from `review_incomplete` if needed), `log.reviewer_started` in task YAML on task branch — git commit + push (first-push-wins)

**Writes (reviewer subprocess — arrives via reap loop):**
- GitHub review comment on impl PR; `ReviewerResult` in `result.json`

**Idempotency guard:** if last log action is already `reviewer_started`, returns `"claim_lost"` immediately.

---

### 3.5 `handleMergeConflicts` + `autoRebase`

**File:** `runtime/orchestrator/src/pr-response/auto-rebase.ts`
**Called from:** `runOneCycle()` step 6 (PR poll), inline — synchronous
**Skill vs code:** orchestrator TypeScript code; spawns Claude CLI synchronously for YAML conflict resolution only (awaited to completion, not broker-mediated)

**Input:** `PrStatusResult[]` where `mergeable === false`; one per impl repo per cycle

**Reads:**
- Task YAML (on task branch in mgmt repo)
- Impl repo working tree (`git rebase origin/feature/{id}`)

**Writes:**
- Mgmt repo: `log.claimed` (claim commit for rebase); push to task branch (first-push-wins)
- Impl repo: `git rebase origin/feature/{id}`; `git push --force-with-lease` on success
- On conflict: commits conflict markers to task branch in impl repo; `task.status = "blocked"`, `blocked_reason: "pr_conflict"` in task YAML; pushes both repos

**Returns:** `"claim_lost" | "rebase_completed" | "rebase_blocked"`

**Key constraint:** requires `implRepoRoot` local filesystem path — breaks under executor isolation (Bug 4).

---

### 3.6 `handleMergedPrs`

**File:** `runtime/orchestrator/src/poll/handle-merged-prs.ts`
**Called from:** `runOneCycle()` step 6, inline after `checkInReviewPrs` — synchronous, awaited
**Skill vs code:** pure TypeScript orchestrator code; Claude is spawned only for YAML conflict resolution (ad-hoc, awaited)

**Input:** `PrStatusResult[]` where `merged === true`

**Reads:**
- Task YAML from task branch (mgmt repo)
- Sibling task YAMLs (same feature, all branches) — for auto-ready cascade
- `status.yaml.feature_branch`

**Writes:**
| What | Where |
|---|---|
| `task.status = "done"`, `pr.status = "merged"`, `log.done` | task YAML on task branch (mgmt repo); commit + push |
| Auto-ready rule: `status: ready`, `log.ready` for dependents | sibling task YAMLs (mgmt repo); commit + push |
| Merge workspace PR (`task-branch` → `feature/{id}`) | GitHub REST `PUT /pulls/{n}/merge` |
| If `checkAllTasksDone()`: calls `fireHandoffTrigger` (§3.9) | — |

---

### 3.7 `handleWorkspacePrRecoveries`

**File:** `runtime/orchestrator/src/poll/check-in-review-prs.ts` (detection) + `main.ts` (retry)
**Called from:** `runOneCycle()` step 6, after `handleMergedPrs` — synchronous
**Skill vs code:** pure orchestrator code

Detects tasks that are `done` on a feature branch but whose workspace PR has not been merged. Retries the GitHub REST merge call. Returns `workspacePrRecoveries[]` from `checkInReviewPrs`.

---

### 3.8 Feature Done Watcher (`handleFeatureDone`)

**File:** `runtime/orchestrator/src/poll/handle-feature-done.ts`
**Called from:** `runOneCycle()` step 7
**Skill vs code:** pure TypeScript — no Claude delegation

**Reads:**
- `status.yaml` — `feature_status`, `handoff_pr_url`, `impl_feature_prs`
  - Primary: `git show origin/feature/{id}:...` (reads from remote feature branch)
  - Fallback: local filesystem (for pre-feature-branch features)
- GitHub REST API: `GET /repos/{owner}/{repo}/pulls/{n}` for each PR URL

**Writes (when all PRs merged):**
1. `git checkout -B feature/{id} origin/feature/{id}` ← **BUG**: fails after `feature/{id}` → `main` PR is merged (GitHub deletes the branch)
2. `status.yaml.feature_status = "done"`, `impl_feature_prs[*].status = "merged"` — commit + push to `feature/{id}`
3. Emit `feature_done`

**Known gaps:**
- `impl_feature_prs` is never populated → always emits `impl_feature_prs_missing`, falls back to checking only `handoff_pr_url`
- `current_stage` is not written to `done`
- No auto-merge of workspace feature PR

**Events emitted:** `impl_feature_prs_missing`, `feature_done_check_failed`, `feature_done_check_skipped`, `feature_done_already`, `feature_done`, `feature_done_push_failed`

---

### 3.9 Handoff Trigger (`fireHandoffTrigger`)

**File:** `runtime/orchestrator/src/handoff/handoff-trigger.ts`
**Called from:** `handleMergedPrs` (step 6) and `dispatchReviewResult` (reap loop) when `checkAllTasksDone()` returns true
**Skill vs code:** pure TypeScript — no Claude delegation

**Reads:**
- All task YAMLs for the feature (from filesystem after checkout of `feature/{id}`)
- `product-spec.md` (for handoff summary)
- GitHub REST API: PR file lists for each task PR (for "Files Changed" section)
- `status.yaml` (title, `handoff_pr_url`)

**Writes:**
| Step | What | Where |
|---|---|---|
| 3 | `handoffs/handoff.md` | mgmt repo working tree |
| 4 | `git commit handoff.md` | `feature/{id}` branch |
| 5 | Promotes draft PR at `handoff_pr_url` from draft → ready-for-review (primary); or creates fresh PR if missing (last resort) | GitHub GraphQL + REST |
| 6 | `status.yaml.handoff_pr_url = prUrl`, `feature_status = "in_handoff"`, `current_stage = "handoff"`, `stages.handoff.pr_url = prUrl` | `feature/{id}` branch |
| 7 | `git push origin feature/{id}` | mgmt repo origin |
| 8 | Slack webhook notification (if `SLACK_WEBHOOK_URL` set) | external |

**Gap:** does NOT open impl repo PRs; does NOT populate `impl_feature_prs`.
**Gap:** PR it promotes is `feature/{id}` → `main`. When merged, GitHub deletes `feature/{id}`.

**Events emitted:** `feature_handoff_triggered`, `handoff_pr_opened`, `handoff_status_yaml_update_failed`, `handoff_push_failed`, `handoff_slack_failed`, `handoff_slack_skipped`

---

### 3.10 `checkInReviewPrs`

**File:** `runtime/orchestrator/src/poll/check-in-review-prs.ts`
**Called from:** step 6 (PR poll)
**Skill vs code:** pure TypeScript

Scans all workspace roots for tasks with `status: in_review` and a `pr.url` set. Calls GitHub GraphQL API per task to fetch `isDraft`, `merged`, `mergeable`. Also detects `done` tasks on feature branches whose workspace PR hasn't merged (returns as `workspacePrRecoveries`).

**Returns:** `{ prResults: PrStatusResult[], workspacePrRecoveries: WorkspacePrRecovery[] }`

No writes. Pure read.

---

### 3.11 `dispatchReviewer` (claim step, §3.4 detail)

**File:** `runtime/orchestrator/src/pr-response/dispatch-reviewer.ts`

Claim protocol:
1. `git fetch + checkout + reset --hard origin/{taskBranch}` on mgmt repo
2. Read task YAML; guard: `status` must be `in_review` or `review_incomplete`; last log ≠ `reviewer_started`
3. Check cycle count ≤ `maxReviewCycles`
4. Write `reviewer_started` log entry; push (first-push-wins)
5. Generate reviewer briefing; `adapter.submit(handleKind: "review")`

---

### 3.12 Reap Loop — `dispatchExecutorResult` (kind: "impl")

**File:** `runtime/orchestrator/src/side-effects/dispatch.ts`

| `terminal_status` | YAML mutation | Other |
|---|---|---|
| `"in_review"` | `task.status = "in_review"`, `task.pr.url = pr_url`, `log.moved_to_review` | Promotes impl PR from draft via GraphQL |
| `"blocked"` or `"failed"` | `task.status = "blocked"`, `blocked_reason` recorded, `pr.url` recorded if present | |

**Max-turns retry guard:** if `blocked_reason` starts with `"max_turns"` and `retryCount < EXECUTOR_MAX_RETRIES`, resets `task.status = "ready"` instead of `"blocked"`.

---

### 3.13 Reap Loop — `dispatchReviewResult` (kind: "review")

**File:** `runtime/orchestrator/src/side-effects/dispatch-review-result.ts`

| `terminal_status` | YAML mutation | Other |
|---|---|---|
| `"passed"` | `writeDoneAndCascade`: `task.status = "done"`, auto-ready cascade for dependents | if `allTasksDone`: `fireHandoffTrigger` |
| `"change_requested"` | `task.status = "change_requested"`, `log.reviewer_complete` | Demotes impl PR back to draft via GitHub API |
| `"escalate"` | `handleEscalation` → `task.status = "blocked"` | Posts Slack alert |
| other / absent | if `review_blocked_count < MAX_REVIEW_INCOMPLETES`: `task.status = "review_incomplete"`, `log.review_blocked`; else: `handleEscalation` | |

---

### 3.14 Reap Loop — `kind: "review-fix"`

**File:** `runtime/orchestrator/src/poll/reap-loop.ts`

Handler exists. Emits `review_dispatch_complete` only — no YAML mutation.
**No code currently dispatches `review-fix` executors.** This is dead code (see §5 Gap 2).

---

## 4. `status.yaml` Fields Written by Orchestrator

| Field | Written by | Lifecycle |
|---|---|---|
| `feature_branch` | Lifecycle Manager step 3 | Once on first run; never overwritten |
| `feature_branch_base_sha` | Lifecycle Manager step 3 | Once on first run; never overwritten (drift baseline) |
| `handoff_pr_url` | Lifecycle Manager step 4 (draft URL) → Handoff Trigger step 6 (same URL, promoted) | Set on first branch creation; not changed after |
| `handoff_pr_promoted` | Lifecycle Manager step 5 | Boolean sentinel; set after GraphQL promotion |
| `feature_status` | Handoff Trigger (`in_handoff`); Feature Done Watcher (`done`) | |
| `current_stage` | Handoff Trigger (`handoff`) | Feature Done Watcher does NOT write `done` |
| `stages.handoff.pr_url` | Handoff Trigger | Mirror of `handoff_pr_url` |
| `impl_feature_prs` | **Nobody** — gap | Never populated |
| `drift_detected` | Feature Review Daemon | |
| `drift_reason` | Feature Review Daemon | |

---

## 5. Skill vs Code Boundary

| Behavior | Implementation |
|---|---|
| Feature branch creation + status.yaml writes | TypeScript (`lifecycle-manager.ts`) |
| Draft PR open + re-promotion | TypeScript (`lifecycle-manager.ts`) |
| Task claim commit | TypeScript (`claim-task.ts`) |
| Workspace PR open (mgmt repo) | TypeScript (`main.ts` / claim) |
| RAG context fetch | TypeScript (`main.ts` — HTTP call to MCP server) |
| Briefing generation | TypeScript (`briefing/` templates) |
| Implementation work | **Claude executor subprocess** (via `adapter.submit`) |
| Fix work | **Claude executor subprocess** (via `adapter.submit`) |
| Code review | **Claude reviewer subprocess** (via `adapter.submit`) |
| Git rebase (clean) | TypeScript (`auto-rebase.ts` — `git rebase` inline) |
| Git rebase (YAML conflict) | **Claude CLI subprocess** (ad-hoc spawn, awaited — not broker-mediated) |
| `handleMergedPrs` (done + cascade + workspace PR merge) | TypeScript (`handle-merged-prs.ts`) |
| Handoff document generation | TypeScript (`handoff-trigger.ts`) |
| Handoff PR promote/create | TypeScript (`handoff-trigger.ts`) |
| Feature done state write | TypeScript (`handle-feature-done.ts`) |
| State invariant checks | TypeScript (`runStateInvariantCheck`) |
| Feature drift detection | TypeScript (`runFeatureReviewCycle`) |
| Feature-level conflict resolution | **Claude reviewer subprocess** (via `adapter.submit`) |
| Reap loop result routing | TypeScript (`reap-loop.ts`) |
| Slack notification | TypeScript (fetch/curlJson webhook call) |

---

## 6. Known Gaps

### Gap 1 — `kind:"rebase"` missing from `HandleKind`

`autoRebase` runs **synchronously inline** in the PR poll step. It requires `implRepoRoot` — a local filesystem path resolved via `resolveRepoLocalPath()`. Under executor isolation (Option D) the orchestrator no longer has local impl repos, making this path non-resolvable.

**Fix:** T5 adds `"rebase"` to `HandleKind`; T6 converts `handleMergeConflicts` to dispatch a `kind:"rebase"` executor subprocess and adds the reap loop handler.

### Gap 2 — `kind:"review-fix"` is dead code

`HandleKind` and `HandleSubkind` in `types.ts` define `"review-fix"` with subkinds `"rebase" | "respond"`. The reap loop has a handler (emits `review_dispatch_complete`). No code path dispatches a `review-fix` executor. `HandleSubkind = "rebase"` was an earlier approach for the auto-rebase executor, superseded by the new `kind:"rebase"`.

**Fix:** out of scope for this feature; leave in place.

### Gap 3 — `handleMergedPrs` blocks the poll cycle

`handleMergedPrs` is called synchronously inline (step 6) and awaited to completion. This includes `git checkout`, `git commit`, `git push`, and `GitHub REST PUT /merge` — all blocking. A slow merge or git operation stalls the entire poll cycle.

**Fix:** T6 defers `handleMergedPrs` to run async (orchestrator code only, not a new executor kind).

### Gap 4 — `impl_feature_prs` never populated

No code path writes `impl_feature_prs`. The Feature Done Watcher emits `impl_feature_prs_missing` every cycle for every `in_handoff` feature.

**Fix:** T3 adds impl repo PR creation to `fireHandoffTrigger` and populates `impl_feature_prs`.

### Gap 5 — Feature branch deleted before done state can be written

`handoff_pr_url` points to `feature/{id}` → `main`. Merging this PR causes GitHub to auto-delete `feature/{id}`. The Feature Done Watcher's next poll calls `git checkout -B feature/{id} origin/feature/{id}` which fails (remote ref gone). Feature stuck in `in_handoff` forever.

**Fix:** T2 + T3 change `handoff_pr_url` semantics so the handoff PR targets `feature/{id}` (not `main`), keeping the feature branch alive. T4 updates the watcher to use the new field and write done state on the still-alive feature branch.

### Gap 6 — Executor filesystem isolation broken

- **local-subprocess:** `syncRepo()` resets the management repo working tree on every cycle with no guard. An executor writing task-branch commits can have its working tree reset mid-write.
- **local-docker:** `TASK_REPO_PATH` is a host filesystem path (`WORKFLOW_LOCAL_PATH` etc.) that does not exist inside containers. `materializeRepo()` always falls through to a full clone at an unresolved path. `HANDLE` absent from subprocess env; `MGMT_REPO_URL` absent from both.

**Fix:** T5 adds `EXECUTOR_WORKDIR`, `HANDLE`, `MGMT_REPO_URL` to ABI; implements two-phase executor startup. T6 updates adapters to pass per-handle env vars and mount per-handle volumes.
