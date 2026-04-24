/# Technical Design

## Feature
- Feature ID: `agent-runtime-pr-merge`
- Title: Agent runtime PR merge — close the loop when an implementation PR is merged

---

## 1. Current State

The agent runtime (`agent-workflow/agent-runtime/`) runs a polling loop in `main.ts`. Each cycle:

1. Pulls all watched workspaces.
2. Scans for `ready` tasks → claims → runs claude.
3. **In-review pass**: calls `checkInReviewPrs` (GraphQL) for every `in_review` task, then:
   - If `mergeable: false` → `handleMergeConflicts` (auto-rebase via Claude).
   - If `hasOpenComments: true` → `handleDraftReviews` (dispatch review agent).

`checkInReviewPrs` (`src/poll/check-in-review-prs.ts`) issues a GraphQL query that fetches `isDraft`, `mergeable`, and `reviewThreads` for each task's implementation PR. It does **not** fetch `merged`. The `PrStatusResult` type has no `merged` field.

There is no handler for the case where the implementation PR is merged. The management-repo PR (`workspace_pr`) and the task YAML status (`in_review`) both remain unchanged after a human merges the implementation PR.

### Existing conflict resolution (already implemented)

When a task's implementation PR reports `mergeable: false`, `handleMergeConflicts` (`src/pr-response/auto-rebase.ts`) runs the following logic:

1. Claims the rebase work via a first-push-wins commit on the management-repo branch.
2. Runs `git rebase origin/<base_branch>` in the implementation repo.
3. **Clean rebase** → force-with-lease push, `conflict_state: resolved`, continue.
4. **Conflicted rebase, all files agent-authored** → spawns `claude` CLI to read each conflicted file, resolve markers, and write resolved content back to disk; then `git rebase --continue`. On success: same as clean path. On failure: falls through to block path.
5. **Conflicted rebase, any file not authored by agent** → blocks immediately (human-authored files are not auto-modified).
6. **Block path** → stages marker files, commits WIP, pushes, sets `status: blocked`, `blocked_reason: pr_conflict`.

This means the runtime already resolves merge conflicts autonomously when possible. The missing piece is what happens **after** the human merges the now-unblocked PR.

### Full in-review lifecycle (current gaps highlighted)

```
PR opened (claim) → task status: in_review
        │
        ▼
  [poll cycle — checkInReviewPrs]
        │
        ├─ mergeable: false ──→ handleMergeConflicts
        │                              │
        │                  ┌───────────┴────────────┐
        │                  │                        │
        │            agent-resolvable        non-agent files
        │           (Claude resolves)        → status: blocked
        │                  │
        │           rebase success
        │           → PR now mergeable
        │           → human can merge
        │
        ├─ hasOpenComments ──→ handleDraftReviews (agent responds)
        │
        └─ merged: true ──→ ⚠️ NO HANDLER (gap this feature fills)
                                  │
                                  ▼
                        mark done + merge workspace PR
```

After conflict resolution or review response, the human merges the implementation PR on GitHub. At that point the runtime has no mechanism to detect the merge and close out the task — the gap this feature fills.

### Existing types and modules relevant to this feature

| Module | Role |
|---|---|
| `src/poll/check-in-review-prs.ts` | Polls GitHub GraphQL for all `in_review` tasks. Returns `PrStatusResult[]`. Pure read. |
| `src/poll/handle-merged-prs.ts` | **Does not exist yet.** Must be created. |
| `src/types/task.ts` | `Task` type, `TaskLogEntry`, `PrStatus`, `workspace_pr: TaskPr | null` |
| `src/task-branch-state.ts` | `tryReadTaskFromBranch` — reads task YAML from `origin/<branch>` via `git show`. |
| `src/claim/open-workspace-pr.ts` | `parseGitHubCoords`, `curlJson`-style REST calls. Pattern for workspace PR merge. |
| `src/git-env.ts` | `buildGitCommitEnv` — constructs env for git add/commit/push. |
| `src/main.ts` | Wires all handlers in `runOneCycle`. |

### Current polling interval config

`config.pr_poll_interval_seconds` in `agent.yaml` controls how often `checkInReviewPrs` runs (line 406–409 of `main.ts`). The merged-PR handler will use the **same interval** — no new env var is needed.

---

## 2. Problem Framing

### What needs to change

1. The GraphQL query in `check-in-review-prs.ts` must include `merged: Boolean!`.
2. `PrStatusResult` must expose `merged: boolean`.
3. A new `handle-merged-prs.ts` must process tasks where `merged: true`:
   - Transition `status: in_review → done` in the task YAML on the feature branch.
   - Update `pr.status → "merged"`.
   - Commit + push the YAML change to the feature branch.
   - Merge the management-repo PR via GitHub REST API.
4. `main.ts` must call `handleMergedPrs` in the in-review pass.

### What must remain stable

- The GraphQL query change is additive — existing callers are unaffected.
- `handleMergeConflicts` and `handleDraftReviews` are not touched. The conflict resolution path (agent rebase) remains exactly as implemented. This feature only adds the terminal step: detecting that the PR was merged after resolution and closing the task.
- Task YAML schema is unchanged — `pr.status: "merged"` is already a valid `PrStatus` value.
- The `workspace_pr` field already exists on the task YAML — the handler reads the PR number from it.
- The polling interval mechanism is unchanged — the merged handler piggybacks on `pr_poll_interval_seconds`.

### Complete conflict → resolution → merge → close pipeline

This feature completes the pipeline that `handleMergeConflicts` starts:

```
conflict detected
  → agent rebases (handleMergeConflicts — existing)
    → PR becomes mergeable
      → human merges
        → merged: true detected (handleMergedPrs — this feature)
          → task marked done + workspace PR merged
```

Tasks that were previously blocked on `pr_conflict` and then unblocked (rebase resolved, human re-reviews and merges) will be caught by the same `merged: true` detection — no special case needed.

### `done` log entry

Merging an implementation PR is treated as the human approval signal. The rule requiring a human log entry for `done` does not apply to this automated close-out path — the PR merge event on GitHub is the authoritative record. The log entry written by the handler records the runtime actor and the source:
- `by:` — runtime's `GIT_AUTHOR_EMAIL`
- `note:` — `"Implementation PR merged — automated close-out by pr-merge loop."`

### Assumptions fixed

- `workspace_pr` is always populated before a task reaches `in_review` (enforced by `openWorkspacePr` at claim time).
- `GITHUB_TOKEN` is already a required env var (enforced by existing runtime).
- The management repo's `owner/repo` coordinates are derivable from `workspace.yaml` via the existing `parseManagementRepoCoords` helper in `main.ts`.

---

## 3. Options Considered

### Option A — REST endpoint for merge detection (poll `GET /repos/{owner}/{repo}/pulls/{number}`)

- **What**: Replace GraphQL with a per-PR REST call that checks `merged` alongside other fields.
- **Pros**: Simple, one call per PR, REST already used by `open-workspace-pr.ts`.
- **Cons**: Removes `reviewThreads` (GraphQL-only field). Would require duplicating the REST response structure alongside the existing GraphQL parser. `hasOpenComments` detection would be lost or require a second call per PR.

**Rejected** — the GraphQL path already handles all fields in one call; adding `merged` is a 3-line change.

### Option B — Separate polling loop for merged PRs (independent timer)

- **What**: A dedicated timer (e.g. `setInterval`) that only checks merged PRs, running independently of the main cycle.
- **Pros**: Configurable at different frequency from the main in-review pass.
- **Cons**: Adds timer management complexity, potential race conditions with the existing in-review pass touching the same task YAMLs.

**Rejected** — the existing `pr_poll_interval_seconds` cadence is appropriate; the merged-PR check naturally belongs in the same in-review pass.

### Option C — Extend GraphQL query + new handler (chosen)

- **What**: Add `merged` to the existing GraphQL query; add a new handler called from `main.ts`.
- **Pros**: Additive change, follows the existing handler pattern (`auto-rebase.ts`), no new timer/config, clean separation.
- **Cons**: None significant.

---

## 4. Chosen Design

### 4a. Extend `check-in-review-prs.ts`

Add `merged` to the GraphQL query:

```graphql
pullRequest(number: $number) {
  isDraft
  merged          # ← new
  mergeable
  reviewThreads(first: 100) { nodes { isResolved } }
}
```

Add `merged: boolean` to `PrStatusResult`:

```typescript
export interface PrStatusResult {
  // ... existing fields ...
  merged: boolean;   // ← new: true when the PR has been merged
}
```

Parse `merged` from the GraphQL response and populate the field. `GitHubGraphQLPrData` gains `merged: boolean`.

### 4b. New `src/poll/handle-merged-prs.ts`

```typescript
export interface HandleMergedPrsOptions {
  prResults: PrStatusResult[];
  workspaceRoot: string;
  /** GitHub owner of the management repo (for workspace PR merge call). */
  mgmtRepoOwner: string;
  /** GitHub repo name of the management repo. */
  mgmtRepoName: string;
  githubToken: string;
  gitAuthorEmail: string;
  gitAuthorName: string;
  sshKeyPath?: string;
  emit: (event: Record<string, unknown>) => void;
}

export async function handleMergedPrs(opts: HandleMergedPrsOptions): Promise<void>
```

**Per-task logic** (for each `result` where `result.merged === true`):

1. **Read live task state from feature branch** using `tryReadTaskFromBranch`. If the task is already `done` or `cancelled`, skip (idempotent guard).
2. **Check `pr.status`** — if already `"merged"`, skip (duplicate guard).
3. **Checkout and sync feature branch** (branch checkout + sync protocol):
   ```bash
   git -C <workspaceRoot> fetch origin
   git -C <workspaceRoot> checkout <taskBranch>
   git -C <workspaceRoot> pull origin <taskBranch>
   ```
4. **Update task YAML** on disk:
   - `status: done`
   - `pr.status: "merged"`
   - `execution.last_updated_by: gitAuthorEmail`
   - `execution.last_updated_at: <timestamp>`
   - Append log entry: `{ action: "done", by: gitAuthorEmail, at: <timestamp>, note: "Implementation PR merged — automated close-out by pr-merge loop." }`
5. **Apply auto-ready rule** — before committing, scan every other task YAML in the same feature whose `depends_on` list includes this task's ID. For each such task where all entries in `depends_on` are now `done`, transition its `status: todo → ready` and append a log entry:
   - `action: ready`
   - `by: gitAuthorEmail`
   - `note: "Task activated — dependency <taskId> merged and marked done."`
   All affected task YAMLs are staged together with the completing task's YAML in a single commit.
6. **Commit + push** to feature branch, with rebase-and-resolve on rejection:
   ```bash
   git -C <workspaceRoot> add <relPaths...>   # completing task + any newly-ready tasks
   git -C <workspaceRoot> commit -m "chore(<taskId>): mark done + activate unblocked tasks"
   git -C <workspaceRoot> push origin <taskBranch>
   ```
   If push is rejected (non-fast-forward), attempt recovery before giving up:
   - **Fetch + rebase**: `git fetch origin` then `git rebase origin/<taskBranch>`.
   - **Clean rebase** → retry push. If push succeeds, continue to step 7.
   - **Conflicted rebase** → spawn `claude` CLI to resolve conflict markers in each affected YAML file (same pattern as `auto-rebase.ts`). YAML conflicts are always machine-generated structured data — a targeted prompt instructs Claude to keep the local `done`/`ready` status and merge the log arrays from both sides.
     - Resolve succeeds → `git rebase --continue` → retry push → continue to step 7.
     - Resolve fails or push still rejected → emit `pr_merge_done_blocked`, stop for this task. The workspace PR merge is skipped. The handler will not retry automatically — operator intervention required.
7. **Merge the workspace PR** via GitHub REST API:
   - Parse `workspace_pr.url` with the existing `parsePrUrl` helper.
   - `PUT /repos/{mgmtRepoOwner}/{mgmtRepoName}/pulls/{prNumber}/merge`
   - Body: `{ merge_method: "merge" }`
   - On success: emit `workspace_pr_merged`.
   - On API error: emit `workspace_pr_merge_failed` with full response. Log and continue — the task YAML is already committed as `done`; the workspace PR remains open for manual merge.

### 4c. Wire in `main.ts`

After the existing `handleDraftReviews` block, add:

```typescript
// ── Merge completion for merged implementation PRs ────────────────────────
if (wsResults.some((r) => r.merged === true)) {
  const mgmtCoords = parseManagementRepoCoords(wsRoot);
  await handleMergedPrs({
    prResults: wsResults,
    workspaceRoot: wsRoot,
    mgmtRepoOwner: mgmtCoords.owner,
    mgmtRepoName: mgmtCoords.repo,
    githubToken,
    gitAuthorEmail,
    gitAuthorName,
    sshKeyPath,
    emit,
  });
}
```

The `parseManagementRepoCoords` helper already exists in `main.ts`.

---

## 5. Dependency Analysis

### Internal dependencies

| Dependency | Status | Notes |
|---|---|---|
| `check-in-review-prs.ts` `PrStatusResult` | **must change first** | `merged` field needed before handler can consume it |
| `task-branch-state.ts` `tryReadTaskFromBranch` | ready | used as-is |
| `open-workspace-pr.ts` `parsePrUrl`, `parseGitHubCoords` | ready | `parsePrUrl` exported and reusable |
| `git-env.ts` `buildGitCommitEnv` | ready | used as-is |
| `main.ts` `parseManagementRepoCoords` | ready | already in scope |
| `types/task.ts` `PrStatus.merged` | already valid | `"merged"` is already a member of the union |

### External dependencies

| Dependency | Status | Notes |
|---|---|---|
| GitHub GraphQL API `PullRequest.merged` | **verified** | `merged: Boolean!` is a standard field on PullRequest |
| GitHub REST API `PUT /repos/.../pulls/{n}/merge` | **verified** | Standard merge endpoint, same auth as existing calls |
| `GITHUB_TOKEN` env var | already required | Existing runtime requirement — no new operator action |

### Blocking decisions

- None. All dependencies are internal to the `workflow` repo and either already exist or are additive changes.

---

## 6. Parallelization / Blocking Analysis

```
T1: Extend poller + implement handle-merged-prs + wire main.ts (workflow)
  └── Can begin now — no blockers

  T2: Documentation update — OPERATOR-GUIDE.md, DOCKER.md (workflow)
      └── BLOCKED on T1 (docs must describe the actual implemented behaviour)
```

T1 is the only implementation task. T2 is a follow-on documentation pass. Both are in the `workflow` repo; no parallel execution opportunity since T2 depends on T1.

---

## 7. Repository Impact

| Repo ID | Files changed | Reason |
|---|---|---|
| `workflow` | `src/poll/check-in-review-prs.ts` | Add `merged` to GraphQL query and `PrStatusResult` |
| `workflow` | `src/poll/handle-merged-prs.ts` (new) | Merge-completion handler |
| `workflow` | `src/main.ts` | Wire `handleMergedPrs` call in in-review pass |
| `workflow` | `agent-runtime/docs/OPERATOR-GUIDE.md` | Document automated merge-close behaviour |
| `workflow` | `agent-runtime/DOCKER.md` | Note that `GITHUB_TOKEN` also enables merge close-out |

No changes to:
- `management-repo` (task YAMLs are written by the runtime at execution time, not design time)
- Any other repo

---

## 8. Validation and Release Impact

### Testing

- Unit test for the extended GraphQL response parsing (new `merged` field in `PrStatusResult`).
- Unit test for `handleMergedPrs`:
  - Already-`done` task → no-op.
  - `pr.status: "merged"` task → no-op.
  - Happy path → task YAML updated, workspace PR merge API called.
  - Push rejection → workspace PR merge skipped, event emitted.
  - Workspace PR merge API error → task YAML `done` retained, error event emitted.

### Backward compatibility

- Additive change to `PrStatusResult`. Existing callers (`handleMergeConflicts`, `handleDraftReviews`) receive the new `merged` field but ignore it — no breakage.
- No schema change to task YAMLs — `pr.status: "merged"` is already a valid value.
- No change to `agent.yaml` schema — `pr_poll_interval_seconds` is reused.

### Rollout

- Deploy runtime image. No config changes required.
- Tasks already `in_review` with merged implementation PRs will be cleaned up on the first poll cycle after deployment.
- If `workspace_pr` is null on any task (was not populated at claim time), the runtime emits `workspace_pr_missing_for_merge` and skips the workspace PR merge step — task is still marked `done`.
