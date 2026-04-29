# Technical Design — Check Status Across All Branches

## Feature
- Feature ID: `check-status-across-all-branches`
- Title: Check status across all branches

## 1. Current State

### File-driven workflow state

The management repo stores workflow state under:

- `docs/features/<feature_id>/status.yaml`
- `docs/features/<feature_id>/tasks/T<n>.yaml`

Task YAML is the machine-readable source of truth for task status, branch, PR
metadata, blocked context, execution metadata, and log entries.

### Dashboard state loading

The `digital-factory-ui` app currently reads task YAML directly from the selected
workspace filesystem:

- `src/lib/tasks.ts` loads `docs/features/<feature_id>/tasks/*.yaml`
- `/tasks` server-renders all tasks through `src/app/tasks/page.tsx`
- `src/app/tasks/tasks-content.tsx` filters the already-loaded task data by active
  workspace on the client

The app has git write helpers in `src/lib/git.ts` for commit-and-push flows, but it
does not currently read task YAML from remote task branches.

### Branch lifecycle convention

Task YAML files include a `branch` value such as:

```text
feature/feature-status-dashboard-v2-T1
```

The workspace also declares the branch pattern:

```yaml
git:
  branch_pattern: "feature/{feature_id}-{work_id}"
```

The agent workflow writes task progress to the task branch before the branch is
merged back into the base branch. Therefore the base-branch working tree can lag
behind the actual task state stored on `origin/feature/<feature_id>-<task_id>`.

### Current limitations

1. The dashboard can display stale task status when a task branch has newer YAML
   than the local base branch.
2. Users must manually fetch/check out branches or inspect PRs to know the latest
   task status.
3. Existing UI refreshes only reread the same local files; they do not reconcile
   branch state.
4. A naive checkout-based sync would disrupt the shared workspace and risk
   overwriting local edits.

## 2. Problem Framing

### What needs to change

- Add a branch-aware task status sync flow in `digital-factory-ui`.
- The sync flow must use git commands to fetch remote task branches and read each
  branch's task YAML without checking out the branch.
- The sync flow must update local task YAML runtime fields when the branch version
  is newer.
- The dashboard should trigger sync every 15 seconds while an active workspace is
  selected, then refresh server-rendered data only when a sync changed task files.

### What must remain stable

- The task YAML schema remains unchanged.
- Existing dashboard readers continue to read `tasks/T<n>.yaml`; they should not
  need to know whether a value came from base branch or branch sync.
- Existing approve/new-feature actions and git commit helper semantics remain
  compatible.
- The workflow runtime remains the owner of task execution. The dashboard sync only
  mirrors task state already committed on task branches.
- The management repo remains git-backed; sync updates are committed and pushed
  rather than left as untracked local edits.

### Fixed assumptions

- The management repo remote is `origin`.
- The workspace's management repo base branch is declared in
  `workspace.yaml -> repos[id=management-repo].base_branch`.
- Branch names are either explicit in `task.branch` or derivable from
  `workspace.yaml -> git.branch_pattern`.
- `digital-factory-ui` runs as a local Next.js app with filesystem access to the
  workspace path.
- A 15-second polling interval is acceptable for the local dashboard.

## 3. Options Considered

### Option A — Read-only branch overlay at render time

The dashboard fetches remote branch YAML on each page render and overlays the
status in memory without writing task YAML back to disk.

**Pros:**
- No commits or push conflicts.
- No risk of mutating the management repo.
- Easy to discard if branch data is invalid.

**Cons:**
- Does not update the file-backed source of truth.
- Every dashboard render repeats git branch reads.
- Other tools that read task YAML still see stale status.
- Does not match the requirement to update task status.

**Implementation impact:** Add branch readers to dashboard data loading only.

**Dependency impact:** No schema changes, but repeated git calls increase render
latency.

**Verdict:** Rejected. Useful as a fallback, but it does not persist synced task
state.

### Option B — Write-back sync from branch YAML to management repo (chosen)

The dashboard fetches remote task branches, reads each task YAML with git commands,
copies newer runtime fields into the local task YAML, commits once per sync cycle,
and pushes to the management repo base branch.

**Pros:**
- Keeps file-backed workflow state current for every tool, not only the dashboard.
- Existing dashboard readers keep working unchanged after sync.
- One sync commit can cover many task updates.
- Git history records when branch state was mirrored.
- Reading branch files with `git show` avoids branch checkout for each task.

**Cons:**
- Needs dirty-worktree and concurrency guards.
- A sync commit can race with a human edit or another dashboard tab.
- Repeated polling must be idempotent to avoid commit noise.

**Implementation impact:** Add a sync service, API route, client poller, and tests.
Reuse/refactor the existing git environment helper for SSH auth.

**Dependency impact:** No new npm dependency required. Continue using `child_process`
for explicit git commands and `js-yaml` for parsing/writing task YAML.

**Verdict:** Chosen.

### Option C — Move sync into `agent-runtime`

The long-running agent runtime polls task branches and writes status updates back
to the management repo independently of the dashboard.

**Pros:**
- Central background process, not tied to an open browser tab.
- Can run even when the dashboard is closed.

**Cons:**
- Changes runtime scope and deployment behavior.
- The requested UX is dashboard sync/polling; adding runtime behavior is a larger
  operational change.
- Duplicates responsibility with the dashboard's local git write surface.

**Implementation impact:** Modify `agent-runtime` polling logic and config.

**Dependency impact:** Requires runtime deployment changes and operator docs.

**Verdict:** Rejected for this feature. It can be revisited later if sync must run
without the UI open.

### Option D — Use GitHub PR API as status source

The dashboard maps task branches to GitHub PRs and derives status from PR state.

**Pros:**
- Can detect PR open/merged/closed state.
- No branch YAML parsing needed for simple PR status.

**Cons:**
- PR state is not task state. It cannot represent `ready`, `in_progress`,
  `blocked_reason`, `blocked_context`, execution metadata, or logs.
- Requires GitHub token/API handling.
- The requirement explicitly calls for git branch status from task branches.

**Implementation impact:** Add GitHub API client and auth config.

**Dependency impact:** New external API dependency and token failure modes.

**Verdict:** Rejected.

## 4. Chosen Design

### Overview

Add a workspace-scoped sync service to `digital-factory-ui`:

```text
Client poller every 15s
  -> POST /api/workspaces/:workspaceId/sync-task-status
     -> fetch origin task refs
     -> scan local tasks
     -> git show origin/<task.branch>:<task_yaml_path>
     -> compare remote branch file freshness vs local base file freshness
     -> copy runtime fields for newer remote tasks
     -> commit + push one sync commit if any task changed
  -> if changed: router.refresh()
```

### Files to add or change

```text
digital-factory-ui/
├── src/app/api/workspaces/[workspaceId]/sync-task-status/route.ts
├── src/components/task-sync/task-status-sync-poller.tsx
├── src/lib/task-status-sync.ts
├── src/lib/git-command.ts
├── src/lib/tasks.ts
├── src/types/task.ts
└── src/app/layout.tsx
```

### Git command wrapper

Add `src/lib/git-command.ts` with a small `runGit()` helper:

```typescript
runGit(repoPath, ["fetch", "origin", "+refs/heads/feature/*:refs/remotes/origin/feature/*", "--prune"])
runGit(repoPath, ["rev-parse", "--verify", "--quiet", `origin/${branch}`])
runGit(repoPath, ["show", `origin/${branch}:${taskYamlPath}`])
runGit(repoPath, ["log", "-1", "--format=%cI", `origin/${branch}`, "--", taskYamlPath])
runGit(repoPath, ["log", "-1", "--format=%cI", "HEAD", "--", taskYamlPath])
```

The helper should:

- Use `child_process.spawn` or `spawnSync` with argument arrays, not shell strings.
- Reuse the existing SSH env behavior from `src/lib/git.ts`
  (`SSH_PRIVATE_KEY`, `SSH_KEY_PATH`, `GIT_SSH_COMMAND`).
- Return structured `{ ok, stdout, stderr, exitCode }`.
- Never throw raw child-process errors without wrapping the git command context.

### Branch resolution

For each task:

1. Use `task.branch` if non-empty.
2. Otherwise derive from `workspace.yaml -> git.branch_pattern`:
   - `{feature_id}` -> feature folder id
   - `{work_id}` -> task id such as `T1`
3. If no branch can be resolved, skip the task with reason
   `missing_branch`.

Example:

```text
feature_id = feature-status-dashboard-v2
work_id    = T1
branch     = feature/feature-status-dashboard-v2-T1
```

### Freshness and regression guard

The sync service must not blindly copy branch YAML over local YAML.

For each task YAML path:

1. Get remote task-file commit time:

   ```text
   git log -1 --format=%cI origin/<branch> -- docs/features/<feature_id>/tasks/T<n>.yaml
   ```

2. Get local task-file commit time on the current checked-out base:

   ```text
   git log -1 --format=%cI HEAD -- docs/features/<feature_id>/tasks/T<n>.yaml
   ```

3. Apply the remote runtime fields only when the remote commit time is newer.
4. If the local task has terminal status `done` or `cancelled` and the remote task
   is older or equal, skip to avoid status regression.
5. If commit time is unavailable, fall back to the newest timestamp from
   `execution.last_updated_at` or the last parseable `log[].at` entry.

### Runtime fields copied from branch YAML

Only copy task runtime fields:

```typescript
const TASK_RUNTIME_FIELDS = [
  "status",
  "blocked_reason",
  "blocked_context",
  "execution",
  "pr",
  "workspace_pr",
  "log",
  "branch",
] as const;
```

Do not copy:

- `id`
- `title`
- `repo`
- `depends_on`

Before copying, validate that the remote YAML `id` matches the local task id. If it
does not match, skip the task with reason `task_id_mismatch`.

### Write and commit flow

The sync service runs once per API request:

1. Acquire a workspace-scoped lock file:

   ```text
   <workspaceRoot>/.git/task-status-sync.lock
   ```

   If the lock exists and is fresh, return `{ ok: true, skipped: "already_running" }`.
   If older than two minutes, remove it as stale.

2. Fetch remote task branches:

   ```text
   git fetch origin +refs/heads/feature/*:refs/remotes/origin/feature/* --prune
   ```

3. Scan all local tasks with the existing `listAllTasksWithContext()`.
4. For each task, read and compare remote task YAML as described above.
5. Write changed local YAML files with deterministic YAML formatting.
6. If no files changed, return `{ ok: true, changed: false }`.
7. Before committing, verify the changed task files are the only files that the
   sync service needs to touch. If a changed task file already has unrelated local
   edits, skip commit and return `dirty_task_file`.
8. Commit all changed task YAMLs in one commit on the management repo base branch:

   ```text
   chore(tasks): sync task status from branches
   ```

9. Push to `origin <base_branch>`.
10. Release the lock.

### API route

Add:

```text
POST /api/workspaces/[workspaceId]/sync-task-status
```

Behavior:

- Resolve the workspace using `getWorkspaceByIdFromScan(workspaceId)`.
- Resolve `management-repo.base_branch` from `workspace.yaml`.
- Call `syncTaskStatusesForWorkspace()`.
- Return a compact JSON result:

```typescript
interface TaskStatusSyncApiResult {
  ok: boolean;
  changed: boolean;
  updated: Array<{ featureId: string; taskId: string; from: string; to: string; branch: string }>;
  skipped: Array<{ featureId: string; taskId: string; branch?: string; reason: string }>;
  error?: string;
}
```

The route must be dynamic and uncached.

### Client polling

Add `TaskStatusSyncPoller` as a client component mounted inside `src/app/layout.tsx`
under `WorkspaceProvider`.

Behavior:

- Read `activeWorkspaceId` from `WorkspaceContext`.
- If no workspace is active, do nothing.
- Run immediately on workspace change, then every 15 seconds.
- Skip while `document.visibilityState !== "visible"`.
- Skip when a request is already in flight.
- POST to the sync API route.
- If `result.changed === true`, call `router.refresh()`.

This keeps server-rendered dashboard, feature detail, and task board views aligned
without adding client-side task data fetching.

### Error handling

| Case | Behavior |
|---|---|
| Branch missing | Skip task; include `branch_missing` in result. |
| Task YAML missing on branch | Skip task; include `remote_task_missing`. |
| Remote YAML invalid | Skip task; include `invalid_remote_yaml`. |
| Remote YAML id mismatch | Skip task; include `task_id_mismatch`. |
| Local task YAML dirty | Do not commit; return `dirty_task_file`. |
| Git fetch fails | Return `ok: false` with stderr summary. |
| Push rejected | Fetch base and return `ok: false`; next poll retries. |
| Concurrent poll | Return `ok: true, changed: false, skipped: already_running`. |

## 5. Dependency Analysis

### Internal dependencies

| Dependency | Status | Notes |
|---|---|---|
| `digital-factory-ui` workspace scanning | Existing | `getWorkspaceByIdFromScan()` already resolves workspace id to path. |
| Task readers | Existing | `listAllTasksWithContext()` already scans feature task YAML. |
| Git auth env | Existing | `src/lib/git.ts` already handles `SSH_PRIVATE_KEY` and `SSH_KEY_PATH`; refactor to share. |
| Task YAML schema | Existing | No schema changes; only runtime fields are copied. |
| Active workspace context | Existing | Poller uses `WorkspaceContext`. |

### External dependencies

| Dependency | Status | Notes |
|---|---|---|
| `git` CLI | Required | The feature explicitly uses git commands. |
| SSH credentials for fetch/push | Required | Same requirement as existing Server Actions. |
| Remote branch naming convention | Required | Uses `task.branch` first, branch pattern fallback second. |

### Blocking decisions

| Decision | Status | Required before |
|---|---|---|
| Poll interval | Resolved: 15 seconds | T2 |
| Source of truth | Resolved: remote task branch YAML | T1 |
| Write target | Resolved: management repo base branch | T1 |
| Branch pattern fallback | Resolved: `feature/<feature_id>-<task_id>` through workspace config | T1 |

No unresolved product decisions remain for the first implementation pass.

### Configuration dependencies

- `WORKSPACE_LIST` must include the management workspace.
- `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` should be set for sync commits.
- `SSH_PRIVATE_KEY` or `SSH_KEY_PATH` must allow `git fetch` and `git push`.
- `workspace.yaml -> repos[id=management-repo].base_branch` must be present.

## 6. Parallelization / Blocking Analysis

Proposed implementation tasks:

```text
T1: Branch sync service and git-command wrapper
  └── Can begin now — no blockers
  │
T2: API route and 15-second client poller
  └── BLOCKED on T1 (sync service contract and result shape must be stable)
  │
T3: Data refresh integration and dashboard smoke coverage
  └── BLOCKED on T2 (poller must know when to call router.refresh)
  │
T4: Documentation and operational notes
  └── BLOCKED on T1 (git command behavior and failure modes must be final)
  └── T3 and T4 can run in parallel after T2/T1 respectively
```

If this feature later receives a formal task breakdown, each task should target
`repo: digital-factory-ui` because the implementation lives in the dashboard app.

## 7. Repository Impact

| Repo id | Impact | Why |
|---|---|---|
| `digital-factory-ui` | Primary implementation | Adds sync service, API route, poller, tests, and shared git command helper. |
| `management-repo` | Runtime write target | Task YAML files are updated by the dashboard sync flow. No schema changes. |
| `workflow` | No implementation change | Agent runtime and workflow skills remain unchanged for this feature. |

Repository ids match `workspace.yaml -> repos[].id`.

## 8. Validation and Release Impact

### Testing expectations

- Unit tests for branch resolution:
  - explicit `task.branch`
  - fallback from `git.branch_pattern`
  - missing branch
- Unit tests for freshness comparison:
  - branch newer updates status
  - branch older does not regress status
  - terminal local statuses are not overwritten by older branch state
- Unit tests for runtime-field copy:
  - copies `status`, `pr`, `blocked_context`, `execution`, `log`
  - does not copy `title`, `repo`, `depends_on`
- Route handler test or integration test for API result shape.
- Manual smoke test:
  1. Create/update a task YAML on a remote task branch.
  2. Open the dashboard with that workspace active.
  3. Wait up to 15 seconds.
  4. Confirm the local task YAML updates and the task board refreshes.

### Migration and compatibility

- No database migration.
- No YAML schema migration.
- Existing tasks without `branch` still work through branch-pattern fallback.
- Existing dashboard pages keep using the same task readers.

### Rollout concerns

- Auto-sync should be enabled only in the local dashboard process. It is not a
  background daemon.
- If the workspace has uncommitted task YAML changes, sync skips rather than
  overwriting them.
- If multiple dashboard tabs are open, the lock prevents overlapping sync writes.
- Push rejection is non-fatal; the next 15-second poll retries after fetch.

### Handoff implications

After implementation, operators should know:

- Task branch YAML is mirrored to the management repo base branch while the
  dashboard is open.
- The dashboard does not execute tasks, merge branches, or infer status from PRs.
- Sync commits use the configured git author identity.
