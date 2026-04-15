# Technical Design

## Feature
- Feature ID: `task-branch-lifecycle`
- Title: Task branch lifecycle — claim, execution, and blocked recovery

## Current State

The current orchestrator flow (bootstrap → eligibility → claim → run-claude) has
three behavioural gaps that this feature must close.

### Gap 1 — Claim commits to `main`, not a task branch

`src/claim/claim-task.ts::claimTask` commits the `ready → in_progress` status change
directly to `baseBranch` (default: `"main"`) and pushes to `origin main`. No task
branch is created or checked out by the orchestrator.

`task.branch` in the task YAML is pre-populated by the human tech-lead author (e.g.
`feature/agent-runtime-hardening-T6`) and never written programmatically by the runtime.
The field exists purely as a briefing hint that `start-implementation` reads and uses.

`start-implementation` creates the task branch on BOTH the management repo and the
implementation repo from inside the Claude subprocess. After `start-implementation`
runs, the management repo's local branch (inside the subprocess's view) is the task
branch. The orchestrator process's own view of the management repo is still `main`.

### Gap 2 — No management-repo PR is ever opened

No code path in the runtime calls the GitHub API to open a PR on the management repo.
The only PR-related code is in the `pr-create` skill, which the agent invokes for the
implementation repo.

### Gap 3 — Blocked exit does not record recoverable context

`src/loop/run-claude.ts::writeBlockedAndPush` commits the blocked YAML state and
pushes to `origin HEAD`. Because the orchestrator's management repo is on `main`,
this pushes the blocked status to `main` — the task branch (if any) has no blocked
state on remote. No `blocked_context` (WIP branch / SHA / timestamp) is recorded.
The next agent has only the `blocked_reason` text to work from.

## Constraints

1. The orchestrator runs one task per container activation. After a successful claim,
   the management repo may be left on the task branch for the duration of that
   container run.
2. `task.branch` is referenced by `agent-context.ts`, `run-claude.ts`, and the
   `start-implementation` skill. Its semantics must not change: it still names the
   task branch on the management repo.
3. `task.pr.url` already tracks the implementation-repo PR (set by `pr-create`).
   The management-repo PR URL must go into a new field to avoid collision.
4. `flushLogAndPush` uses `git push origin "${taskBranch}"`. After the orchestrator
   switches to the task branch at claim time, this push will fast-forward correctly
   as long as the agent subprocess has not diverged the remote branch. A diverged
   push (agent committed+pushed after `runClaude` started) is an existing interleave
   risk; it is out of scope for this feature.
5. `GITHUB_TOKEN` is already available to agents via the project `.env`. The
   orchestrator must be able to read it from `process.env` (set by bootstrap).
6. The `blocked_reason` field on `Task` is the existing `BlockedReason` enum (string
   literal union). `blocked_context` is a separate, optional sub-object that carries
   the WIP branch, SHA, and timestamp. These are distinct fields — do not conflate.

## Options Considered

### D1 — Where the management-repo branch is created

**Option A (chosen): `claimTask` creates the task branch and commits there**

The orchestrator creates `feature/<featureId>-<taskId>` before committing the claim
status. The management repo is on the task branch from the moment the claim succeeds.
`start-implementation` detects that the branch already exists (it was just pushed by
`claimTask`) and checks out the remote branch instead of creating a new one.

- Pros: branch lifecycle starts in the orchestrator, not inside the Claude subprocess;
  all subsequent orchestrator git operations (log sink, blocked push) automatically
  land on the task branch; matches the product spec (claim creates the branch).
- Cons: `start-implementation` SKILL.md must be updated to handle the pre-existing
  management-repo branch.

**Option B: `start-implementation` continues to create the branch**

No change to `claimTask`. The branch is still created inside the Claude subprocess.

- Pros: no change to `claimTask`.
- Cons: does not match product spec (branch is not created at claim time);
  orchestrator log sink continues to push incorrectly; blocked push continues to
  land on `main`; PR cannot be opened at claim time because the branch does not
  exist yet.

### D2 — Where `task.branch` comes from

**Option A (chosen): `claimTask` derives and writes `task.branch`**

`claimTask` computes `branch = feature/${featureId}-${taskId}` and writes it to
the task YAML as part of the claim mutation. If `task.branch` is already set in
the YAML (old tasks), the computed name overrides it. The TASK.template.yaml no
longer pre-sets `branch` (set to empty string; `claimTask` fills it in).

- Pros: single source of truth for the branch naming convention; no human error in
  task authoring; consistent across all tasks.
- Cons: existing task YAMLs with a non-standard branch name would be silently
  overridden at claim time. (In practice, all existing tasks follow the same
  `feature/<featureId>-<taskId>` convention so no override occurs.)

**Option B: Keep pre-set `task.branch` in YAML; `claimTask` reads and uses it**

- Pros: backward compatible; explicit per-task override.
- Cons: human error possible; does not enforce the canonical naming; branch could
  be any arbitrary string.

### D3 — Contention detection on the task branch

**Option A (chosen): same SHA-comparison protocol, applied to the task branch**

`claimTask` creates the task branch from the latest main, commits, and pushes to
`origin feature/<featureId>-<taskId>`. Two agents racing on the same task create the
branch from the same main HEAD, write identical status YAMLs (both change status to
`in_progress`), and race to push. First push wins (fast-forward). The loser gets a
non-fast-forward rejection; it fetches origin and compares SHA. If SHA differs,
another agent won; if SHA matches, this agent's commit landed despite the rejection.

The push rejection is harder to interpret when the branch does not yet exist on
remote: GitHub accepts the first push unconditionally. Two agents calling
`git push origin feature/...` for the first time cannot both win — one will get a
non-fast-forward rejection once the branch exists with the other agent's commit. The
existing SHA-comparison logic handles this correctly.

- Pros: no new contention mechanism needed; same protocol, different target branch.
- Cons: if neither agent has yet pushed (branch does not exist), the window for
  a simultaneous "first push" race is narrow but not zero. The pre-commit jitter
  (50–500 ms) mitigates this to an acceptable level.

### D4 — PR opening at claim time

**Option A (chosen): new `openWorkspacePr` function in `src/claim/`**

GitHub REST API via `curl` (not `gh` CLI, matching `pr-create` skill convention).
Called from `main.ts` after `claimTask` returns `{ won: true }`.  Returns the PR
URL, which is stored in `task.workspace_pr`. Checks for an existing open PR first
to avoid duplicates (handles branch-already-exists re-claim).

- Pros: clean separation between git atomicity (`claimTask`) and GitHub API
  (`openWorkspacePr`); `claimTask` remains testable without network access.
- Cons: an extra GitHub API round-trip per activation cycle.

**Option B: fold PR opening into `claimTask`**

- Pros: single function call from `main.ts`.
- Cons: `claimTask` gains a network dependency, breaking unit-test isolation.

### D5 — `blocked_context` in the task YAML

**Option A (chosen): new optional sub-object on `Task`; written by orchestrator**

`src/loop/run-claude.ts::writeBlockedAndPush` (already called when the task is still
`in_progress` after claude exits) is extended to also write `blocked_context`. The
`start-implementation` SKILL.md is updated to check this field on entry and branch
into recovery mode when non-null.

**Option B: write `blocked_context` inside the Claude subprocess (agent-side)**

The agent writes it via the `start-implementation` blocking exit rule. This is the
*only* path if the agent exits normally with `status: blocked`.

- Chosen combination: agent handles the graceful-block path (already documented in
  `start-implementation`); orchestrator handles the crash path (task still
  `in_progress` after subprocess exit).

### D6 — Blocked recovery PR inheritance

**Option A: reuse open PR if it exists; open `-<attempt>` branch if not**

If the original PR was closed, create a new branch with a numeric suffix
(`-2`, `-3`, …) and open a PR from that. Write the new branch name to
`blocked_context.wip_branch` so the next recovery knows where to look.

- Pros: every PR has exactly one branch; no branch reuse across attempts.
- Cons: requires counting prior attempts; `blocked_context.wip_branch` drifts
  from the canonical `feature/<featureId>-<taskId>` name; recovery reads a
  different branch each attempt, adding complexity with no clear benefit.

**Option B (chosen): always stay on the canonical branch; open a new PR if closed**

`openWorkspacePr` checks for an existing open PR on `feature/<featureId>-<taskId>`.
- If found: continue using it. No new PR opened.
- If closed (or not found): open a **new PR on the same branch**. The branch is
  never renamed; `blocked_context.wip_branch` always equals the canonical name.

- Pros: no suffix counting; `blocked_context.wip_branch` is always the canonical
  branch name; `openWorkspacePr` logic is the same for claim and recovery;
  the branch accumulates the full commit history across all recovery attempts.
- Cons: requires one GitHub API search call to check for an open PR.

## Chosen Design

### New naming helper (`paths.ts`)

Add a single canonical helper:
```typescript
export function taskBranchName(featureId: string, taskId: string): string {
  return `feature/${featureId}-${taskId}`;
}
```
All callers that currently build the branch name inline must use this helper.

### Task type additions (`types/task.ts`)

```typescript
export interface BlockedContext {
  wip_branch: string;   // branch that holds the WIP commit
  wip_sha: string;      // SHA of the WIP commit
  pushed_at: string;    // ISO 8601 timestamp
}

// Added to Task interface:
blocked_context: BlockedContext | null;

workspace_pr: {          // management-repo PR (opened at claim time)
  url: string;
  status: PrStatus;
} | null;
```

`blocked_context` is `null` when the task has never been blocked or after a
successful recovery. `workspace_pr` is `null` until `openWorkspacePr` succeeds.

### `claimTask` rewrite (`src/claim/claim-task.ts`)

New claim sequence (replaces current commit-to-main):

```
1. git -C <workspaceRoot> fetch origin
2. git -C <workspaceRoot> reset --hard origin/<baseBranch>
   (orchestrator is now on clean main)
3. Read task YAML; verify status === "ready"
4. Determine branch = taskBranchName(featureId, taskId)
5. Check if branch exists on remote:
   a. NOT exists: git checkout -b <branch>
   b. EXISTS, task.blocked_context null:
        git checkout <branch>
        git reset --hard origin/<branch>
        (prior interrupted claim — inherit the branch)
   c. EXISTS, task.blocked_context non-null:
        return { won: false, reason: "branch_blocked_recovery" }
        (caller handles S5 path)
6. Pre-commit jitter (50–500 ms)
7. Mutate task YAML: status → in_progress, branch → derived name,
   clear blocked_context (set null if non-null), append "claimed" log entry
8. git add <relPath> && git commit -m "chore(<taskId>): claim — status in_progress"
9. git push origin <branch>
   - Push rejected: compare SHA; lost → tryResetToRemote(baseBranch); return { won: false }
   - Push won: continue
10. Post-claim verify (re-read YAML, confirm status + actor)
11. Return { won: true }
```

`ClaimResult` gains a new failure reason:
```typescript
| { won: false; reason: "branch_blocked_recovery" }
```

`main.ts` must check for `branch_blocked_recovery` and route to the S5 flow.

### `openWorkspacePr` (new `src/claim/open-workspace-pr.ts`)

```typescript
export interface OpenWorkspacePrOpts {
  workspaceRoot: string;
  featureId: string;
  taskId: string;
  branch: string;
  baseBranch: string;
  githubToken: string;
  // github.com/<owner>/<repo> resolved from workspace.yaml management_repo
  repoOwner: string;
  repoName: string;
}

export interface OpenWorkspacePrResult {
  prUrl: string;
  prNumber: number;
  alreadyExisted: boolean;
}
```

Steps:
1. `GET /repos/<owner>/<repo>/pulls?head=<owner>:<branch>&state=open` — check for
   existing open PR.
2. If found: return `{ prUrl, prNumber, alreadyExisted: true }`.
3. If not found: `POST /repos/<owner>/<repo>/pulls` with title, body, head, base.
4. Write the PR URL + `status: open` to `task.workspace_pr` in the task YAML.
5. Commit and push the YAML update to the task branch.

All GitHub API calls use `curl` (not `gh` CLI). Authentication via
`Authorization: token <githubToken>`.

The `repoOwner` and `repoName` are parsed from `workspace.yaml -> repos[]` where
`id === management_repo`. The `github` field holds the SSH URL
(`git@github.com:<owner>/<repo>.git`); the owner/repo are extracted with a regex.

### `main.ts` changes

After `claimTask` returns `{ won: true }`:
```typescript
const taskBranch = taskBranchName(featureId, task.id);
// Open management-repo PR
const { repoOwner, repoName } = parseManagementRepoCoords(workspaceLocalPath);
await openWorkspacePr({
  workspaceRoot: workspaceLocalPath,
  featureId, taskId: task.id, branch: taskBranch, baseBranch,
  githubToken: process.env.GITHUB_TOKEN ?? "",
  repoOwner, repoName,
});
```

After `claimTask` returns `{ won: false, reason: "branch_blocked_recovery" }`:
- Log `task_blocked_recovery_entry` event.
- Derive blocked recovery flow: fetch WIP branch, read `blocked_context`, proceed
  to `runClaude` with the WIP branch context.
- Still opens a PR via `openWorkspacePr` (which will find the existing one or open
  a new `-<attempt>` branch PR).

`taskBranch` passed to `generateAgentContext` and `runClaude` is now always derived
via `taskBranchName(featureId, taskId)` (not read from `task.branch`), although
`task.branch` will contain the same value after `claimTask` sets it.

### `run-claude.ts` changes

`writeBlockedAndPush` gains a `blocked_context` write:
```typescript
task.blocked_context = {
  wip_branch: taskBranch,
  wip_sha: getHeadSha(workspaceRoot),   // execSync git rev-parse HEAD
  pushed_at: new Date().toISOString(),
};
```
This runs only on the crash path (task still `in_progress` after subprocess exit).
The graceful-block path (agent writes `blocked_context` itself via
`start-implementation`'s blocking exit rule) is handled inside the subprocess.

### `start-implementation` SKILL.md changes

**Management-repo setup (normal claim):**

Replace the current "create branch on both repos" instruction with:

- Implementation repo: `git fetch origin && git checkout -b feature/<featureId>-<taskId>` (unchanged)
- Management repo: **branch already exists** (created by `claimTask`):
  ```
  git fetch origin
  git checkout feature/<featureId>-<taskId>
  git reset --hard origin/feature/<featureId>-<taskId>
  ```
  Hard stop if checkout fails (branch unexpectedly missing).

**Blocked recovery mode (new, S5):**

Triggered when task `status === "ready"` AND `task.blocked_context` is non-null.
Instead of the normal branch setup:
```
git fetch origin
git checkout <blocked_context.wip_branch>
git reset --hard origin/<blocked_context.wip_branch>
```
Append a `recovery_started` log entry. Read `blocked_reason` and
`suggested_next_step` as context before implementing.

On successful PR creation: set `blocked_context: null` in the task YAML, commit,
and push to the task branch.

**Blocking exit rule (updated):**

When setting `status: blocked` during graceful exit, the agent must also:
1. `git add -A && git commit -m "wip: partial work before block — <summary>"` on the task branch (implementation repo).
2. `git push origin <branch>` on the implementation repo.
3. Write `blocked_context` to the task YAML:
   ```yaml
   blocked_context:
     wip_branch: feature/<featureId>-<taskId>
     wip_sha: <output of git rev-parse HEAD on impl repo>
     pushed_at: <ISO 8601 now>
   ```
4. Commit the task YAML update to the management repo task branch.
5. Push the management repo task branch.

### `TASK.template.yaml` change

Remove the pre-set `branch` value (set to empty string `""`). `claimTask` writes
the correct value at claim time. Add new optional fields:

```yaml
blocked_context: null
workspace_pr: null
```

## Repository Impact

| File | Change |
|---|---|
| `agent-runtime/src/paths.ts` | Add `taskBranchName(featureId, taskId)` |
| `agent-runtime/src/types/task.ts` | Add `BlockedContext`, `blocked_context`, `workspace_pr` |
| `agent-runtime/src/claim/claim-task.ts` | Rewrite: branch creation, task-branch push, blocked-recovery detection |
| `agent-runtime/src/claim/open-workspace-pr.ts` | New: GitHub API PR creation + dedup |
| `agent-runtime/src/main.ts` | Call `openWorkspacePr` after claim; handle `branch_blocked_recovery`; derive `taskBranch` |
| `agent-runtime/src/loop/run-claude.ts` | `writeBlockedAndPush`: write `blocked_context` on crash-block path |
| `agent-runtime/src/bootstrap/agent-context.ts` | No change (task.branch semantics unchanged) |
| `workflow_skills/start-implementation/SKILL.md` | Management-repo checkout (not create); add blocked re-do mode; update blocking exit rule |
| `templates/feature/tasks/TASK.template.yaml` | Remove pre-set `branch`; add `blocked_context: null`, `workspace_pr: null` |

No new `npm` dependencies. GitHub API calls use Node.js built-in `child_process`
via `curl` (consistent with `pr-create` skill convention).

## Dependency Analysis

```
T1: paths.ts + types/task.ts (schema foundations)
T2: claim-task.ts rewrite          ← depends on T1
T3: open-workspace-pr.ts (new)     ← depends on T1
T4: main.ts wiring                 ← depends on T2 + T3
T5: run-claude.ts blocked_context  ← depends on T1
T6: start-implementation SKILL.md  ← depends on T1 (schema), independent of T2–T5
T7: TASK.template.yaml             ← independent (YAML only)
```

T7 (template update) has no code dependencies and can run any time.

## Parallelization / Blocking Analysis

```
Wave 1 (independent): T1, T7
Wave 2 (unblock after T1): T2, T3, T5, T6
Wave 3 (unblock after T2 + T3): T4
```

Wave 2 tasks (T2, T3, T5, T6) are mutually independent and may be executed in
parallel. T4 integrates all of them and must wait for T2 and T3 specifically
(T5 and T6 change behavior that T4 exercises but do not change T4's call sites).

Test strategy:
- T2 (`claimTask`): extend existing unit tests for branch creation, branch-exists
  cases, and `branch_blocked_recovery` return.
- T3 (`openWorkspacePr`): unit test with mocked `curl` responses; test dedup path.
- T4 (`main.ts`): integration test — full activation cycle with stub workspace.
- T5 (`run-claude.ts`): extend existing tests for `writeBlockedAndPush` to assert
  `blocked_context` fields are written.
- T6 (`start-implementation`): skill-level test — verify management-repo checkout
  branch-exists path and blocked recovery mode.
