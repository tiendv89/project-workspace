# Tasks — task-branch-lifecycle

> Feature status: `in_tdd` — technical design approved 2026-04-15.
> Task stage: **draft** — awaiting human approval.
>
> Narrative (description + required skills + subtasks) lives in this file. Machine-readable state (status, deps, branch, log, PR) lives per-task in `tasks/T<n>.yaml`. Agents mutate only the YAML files; this document stays stable unless scope changes.
>
> All TypeScript tasks (T1–T5) target the `workflow` repo (`agent-runtime/` subdirectory) and require `typescript-best-practices`. T6 (skill doc) and T7 (template YAML) are text-only changes with no required skills.

---

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Schema foundations — paths.ts + types/task.ts | — |
| T7 | 1 | TASK.template.yaml update | — |
| T2 | 2 | claim-task.ts rewrite — task-branch creation and push | T1 |
| T3 | 2 | open-workspace-pr.ts — GitHub API PR creation for management repo | T1 |
| T5 | 2 | run-claude.ts — write blocked_context on crash-block path | T1 |
| T6 | 2 | start-implementation SKILL.md — checkout, recovery mode, exit rule | T1 |
| T4 | 3 | main.ts wiring — integrate claim branch + openWorkspacePr + S5 routing | T2, T3 |

Wave 1 tasks (T1, T7) have no dependencies and can start immediately. Wave 2 tasks
(T2, T3, T5, T6) are mutually independent and may all run in parallel once T1 is
merged. T4 integrates T2 and T3 and must wait for both.

---

## T1 — Schema foundations — paths.ts + types/task.ts

### Description

Lays the canonical types and path helpers that all other tasks depend on. No
behaviour changes — this task is purely additive.

**`src/paths.ts`** — add one helper:
```typescript
export function taskBranchName(featureId: string, taskId: string): string {
  return `feature/${featureId}-${taskId}`;
}
```
All callers that currently construct branch names inline must use this function
instead of hardcoding the pattern.

**`src/types/task.ts`** — add three declarations:
```typescript
export interface BlockedContext {
  wip_branch: string;   // management-repo branch holding the WIP commit
  wip_sha: string;      // SHA of the WIP commit on that branch
  pushed_at: string;    // ISO 8601 timestamp of the push
}
```
Add to the `Task` interface:
```typescript
blocked_context: BlockedContext | null;
workspace_pr: TaskPr | null;   // management-repo PR (opened at claim time)
```
`blocked_context` is `null` when the task has never been blocked or after a
successful recovery. `workspace_pr` is `null` until `openWorkspacePr` succeeds.
Use the existing `TaskPr` type (`{ url: string; status: PrStatus }`) for `workspace_pr`.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] `src/paths.ts`: add `taskBranchName(featureId, taskId)` after the existing path helpers. Export it.
- [ ] `src/types/task.ts`: add `BlockedContext` interface above the `Task` interface.
- [ ] `src/types/task.ts`: add `blocked_context: BlockedContext | null` and `workspace_pr: TaskPr | null` to the `Task` interface. Place them after the existing `pr` field.
- [ ] Run `tsc --noEmit` — must pass with zero errors.
- [ ] Acceptance: `tsc --noEmit` clean; `taskBranchName("foo", "T3")` returns `"feature/foo-T3"`; `Task` type includes both new fields.

---

## T7 — TASK.template.yaml update

### Description

Small update to `templates/feature/tasks/TASK.template.yaml` to reflect the new
task schema after this feature ships. Three changes:

1. Set `branch: ""` — `claimTask` will derive and write the correct value at
   claim time; the field should not be pre-set by the human task author.
2. Add `blocked_context: null` — makes the field explicit in every new task file.
3. Add `workspace_pr: null` — makes the field explicit in every new task file.

No TypeScript changes. No dependencies.

### Required skills

### Subtasks
- [ ] `templates/feature/tasks/TASK.template.yaml`: set `branch: ""`.
- [ ] Add `blocked_context: null` after `blocked_reason: null`.
- [ ] Add `workspace_pr: null` after the `pr:` block.
- [ ] Acceptance: diff the file and confirm only the three fields are changed.

---

## T2 — claim-task.ts rewrite — task-branch creation, branch-exists cases, task-branch push

### Description

The core behavioural change. `claimTask` currently commits the claim status
directly to `main`. After this task it creates `feature/<featureId>-<taskId>`,
commits there, and pushes the task branch — making the management repo switch to
the task branch from the moment the claim succeeds.

**New claim sequence** (full replacement of the existing commit-to-main logic):

```
1. git fetch origin
2. git reset --hard origin/<baseBranch>          ← orchestrator now on clean main
3. Read task YAML; verify status === "ready"
4. branch = taskBranchName(featureId, taskId)    ← via T1 helper
5. Check remote branch existence:
   a. NOT exists  → git checkout -b <branch>
   b. EXISTS, blocked_context null
              → git checkout <branch>
                git reset --hard origin/<branch>   ← interrupted prior claim
   c. EXISTS, blocked_context non-null
              → return { won: false, reason: "branch_blocked_recovery" }
6. Pre-commit jitter (50–500 ms)
7. Mutate YAML: status → in_progress, branch → derived name,
   append "claimed" log entry
8. git add <relPath> && git commit -m "chore(<taskId>): claim — status in_progress"
9. git push origin <branch>
   rejected → compare SHA; lost → tryResetToRemote(baseBranch); return { won: false }
10. Post-claim verify (re-read YAML, confirm status + actor)
11. return { won: true }
```

`ClaimResult` gains a new failure reason:
```typescript
| { won: false; reason: "branch_blocked_recovery" }
```

The remote branch existence check uses:
```bash
git ls-remote --exit-code origin <branch>
```
Exit code 0 = branch exists; exit code 2 = does not exist.

The existing `tryResetToRemote` helper resets to `baseBranch`, not the task
branch — this is intentional (on loss, the orchestrator returns to a clean main).

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Import `taskBranchName` from `../paths.js`.
- [ ] Add `"branch_blocked_recovery"` to the `ClaimResult` union type.
- [ ] Add step 1–2 (`fetch` + `reset --hard origin/<baseBranch>`) before reading the task YAML. Hard stop on failure: `tryResetToRemote` then `return { won: false, reason: "push_rejected" }`.
- [ ] After verifying `status === "ready"`, compute `branch = taskBranchName(featureId, taskId)`.
- [ ] Check remote branch existence with `git ls-remote --exit-code origin <branch>`. Handle the three cases (not exists, exists+no blocked_context, exists+blocked_context non-null) as described above.
- [ ] In the YAML mutation (step 7): set `task.branch = branch`. Do not touch `blocked_context` in the normal claim path (it is already null for a fresh ready task).
- [ ] Change the `git push` target from `baseBranch` to `<branch>`. Update `tryResetToRemote` calls to still reset to `baseBranch` (not the task branch) on loss.
- [ ] Update or add unit tests to cover: (a) normal fresh claim creates branch and pushes there; (b) branch exists + no blocked_context → checkout + push wins; (c) branch exists + blocked_context → returns `branch_blocked_recovery`; (d) push rejected by concurrent agent.
- [ ] Run `tsc --noEmit` — must pass.
- [ ] Acceptance: unit tests pass; `tsc --noEmit` clean; after a successful claim the management repo local branch is the task branch, not main.

---

## T3 — open-workspace-pr.ts — GitHub API PR creation and dedup for management repo

### Description

New module `src/claim/open-workspace-pr.ts` that opens a PR from the task branch
to `main` on the management repo at claim time, or finds the existing open PR if
the branch was previously claimed.

**Interface:**
```typescript
export interface OpenWorkspacePrOpts {
  workspaceRoot: string;
  featureId: string;
  taskId: string;
  branch: string;         // task branch, e.g. feature/task-branch-lifecycle-T3
  baseBranch: string;     // PR target, e.g. "main"
  githubToken: string;
  repoOwner: string;      // parsed from workspace.yaml management repo SSH URL
  repoName: string;
}

export interface OpenWorkspacePrResult {
  prUrl: string;
  prNumber: number;
  alreadyExisted: boolean;
}
```

**Steps:**
1. `GET /repos/<owner>/<repo>/pulls?head=<owner>:<branch>&state=open` — check for
   an existing open PR. If found, use it (`alreadyExisted: true`).
2. If not found: `POST /repos/<owner>/<repo>/pulls` — create a new PR with title
   `feat(<taskId>): <taskTitle>` and a minimal body.
3. Write the PR URL + `status: "open"` to `task.workspace_pr` in the task YAML.
4. Commit the YAML change and push to the task branch.

All HTTP calls use `curl` via `execSync` (no `gh` CLI, no `fetch` — consistent
with `pr-create` skill). Authentication: `Authorization: token <githubToken>`.

`repoOwner` and `repoName` are extracted from the management repo's SSH URL
(`git@github.com:<owner>/<repo>.git`) using a regex. The SSH URL comes from
`workspace.yaml -> repos[]` where `id === management_repo` value.

A helper `parseGitHubCoords(sshUrl: string): { owner: string; repo: string }`
should be exported so `main.ts` can call it once rather than duplicating the regex.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Create `src/claim/open-workspace-pr.ts` with `OpenWorkspacePrOpts`, `OpenWorkspacePrResult`, `openWorkspacePr`, and `parseGitHubCoords` exports.
- [ ] `parseGitHubCoords`: regex `git@github.com:([^/]+)/([^.]+)(?:\.git)?$` — throw a descriptive error if the URL does not match.
- [ ] `openWorkspacePr` step 1: call GitHub `GET /pulls?head=...&state=open` via `curl -s`. Parse the JSON response; if `length > 0`, use the first result.
- [ ] `openWorkspacePr` step 2: if no open PR, call `POST /pulls` with title and body. Parse the response for `html_url` and `number`.
- [ ] `openWorkspacePr` step 3–4: read task YAML, set `task.workspace_pr = { url: prUrl, status: "open" }`, write file, `git add`, `git commit -m "chore(<taskId>): open workspace PR"`, `git push origin <branch>`.
- [ ] Unit tests: mock `curl` responses (spawnSync mock or fixture JSON); test (a) existing open PR found — no POST call, returns `alreadyExisted: true`; (b) no open PR — POST called, PR URL written to YAML; (c) `parseGitHubCoords` parses standard and `.git`-less SSH URLs; (d) `parseGitHubCoords` throws on HTTPS URL.
- [ ] Run `tsc --noEmit` — must pass.
- [ ] Acceptance: unit tests pass; function correctly deduplicates on re-claim.

---

## T5 — run-claude.ts — write blocked_context on crash-block path

### Description

Extends `writeBlockedAndPush` in `src/loop/run-claude.ts` to write `blocked_context`
when the orchestrator forces a block (the crash path: task is still `in_progress`
after the Claude subprocess exits).

The graceful-block path (agent calls `/start-implementation` which sets
`status: blocked` itself) is handled inside the subprocess (T6). This task only
covers the crash path in the orchestrator.

**Change to `writeBlockedAndPush`:**
```typescript
const wipSha = execSync(
  `git -C "${workspaceRoot}" rev-parse HEAD`,
  { encoding: "utf-8", stdio: "pipe" },
).trim();

task.blocked_context = {
  wip_branch: taskBranch,   // passed in as a new parameter
  wip_sha: wipSha,
  pushed_at: new Date().toISOString(),
};
```

`taskBranch` must be added as a parameter to `writeBlockedAndPush` (already
available at the call site in `runClaude`).

After this change, a crash-blocked task will always have `blocked_context`
populated, enabling the S5 recovery flow.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add `taskBranch: string` parameter to `writeBlockedAndPush`.
- [ ] Inside `writeBlockedAndPush`, after setting `task.blocked_reason`, add the `blocked_context` write using `git rev-parse HEAD` on the management repo.
- [ ] Update the two call sites of `writeBlockedAndPush` in `runClaude` to pass `taskBranch`.
- [ ] Update unit/integration tests for `writeBlockedAndPush` to assert that `blocked_context` is written with a non-null `wip_branch`, `wip_sha`, and `pushed_at`.
- [ ] Run `tsc --noEmit` — must pass.
- [ ] Acceptance: unit tests pass; `tsc --noEmit` clean; after a crash-block, the task YAML on disk contains a non-null `blocked_context`.

---

## T6 — start-implementation SKILL.md — management-repo checkout, blocked recovery mode, blocking exit rule

### Description

Three targeted updates to `workflow_skills/start-implementation/SKILL.md`. No
TypeScript changes — this is a skill document update only.

**Change 1 — Management-repo branch setup (normal claim)**

Replace the current instruction that creates the branch on both repos:

> For **both** the implementation repo and the management repo: … 3. Create the feature branch: `git checkout -b feature/<feature_id>-<work_id>`

With separate instructions:
- **Implementation repo**: unchanged — still creates a fresh branch.
- **Management repo**: branch already exists (created by `claimTask`). Do:
  ```
  git fetch origin
  git checkout feature/<featureId>-<taskId>
  git reset --hard origin/feature/<featureId>-<taskId>
  ```
  Hard stop if checkout fails (branch unexpectedly missing on remote).

**Change 2 — Blocked recovery mode (new section)**

Add a new `## Blocked recovery mode` section below `## Re-do mode`:

> Triggered when task `status === "ready"` AND `task.blocked_context` is non-null.
> Use this mode instead of normal setup when these conditions are both true.
>
> 1. Fetch origin on both repos.
> 2. Management repo: `git checkout <blocked_context.wip_branch> && git reset --hard origin/<wip_branch>`.
> 3. Implementation repo: `git checkout <blocked_context.wip_branch> && git reset --hard origin/<wip_branch>` (same branch name used on both repos).
> 4. Read `blocked_reason` and `suggested_next_step` as additional context before implementing.
> 5. Append a `recovery_started` log entry to the task YAML.
> 6. On successful PR creation: set `blocked_context: null` in the task YAML, commit the change, push to the task branch.

**Change 3 — Blocking exit rule (updated)**

The existing rule says to set `status: blocked`, write `blocked_reason` and
`suggested_next_step`, and exit. Extend it with the WIP commit steps:

> Before setting `status: blocked`:
> 1. `git add -A && git commit -m "wip: partial work before block — <summary>"` on the **implementation repo** task branch.
> 2. `git push origin <branch>` on the implementation repo.
> 3. Capture the WIP commit SHA: `git rev-parse HEAD` on the implementation repo.
> 4. Write `blocked_context` to the task YAML:
>    ```yaml
>    blocked_context:
>      wip_branch: feature/<featureId>-<taskId>
>      wip_sha: <SHA from step 3>
>      pushed_at: <ISO 8601 now>
>    ```
> 5. Then set `status: blocked`, write `blocked_reason` + `suggested_next_step`, append log entry.
> 6. Commit and push the task YAML to the management repo task branch.

### Required skills

### Subtasks
- [ ] `workflow_skills/start-implementation/SKILL.md`: replace the "both repos" branch creation instruction with the split impl/management-repo instructions described above.
- [ ] Add the `## Blocked recovery mode` section after `## Re-do mode`.
- [ ] Update the blocking exit rule in `## Autonomous execution rules` to include the WIP commit + `blocked_context` steps.
- [ ] Acceptance: a dry-read of the updated skill document shows no remaining "create the feature branch on the management repo" language; blocked recovery and blocking exit rules are unambiguous.

---

## T4 — main.ts wiring — openWorkspacePr after claim, S5 routing, taskBranch derivation

### Description

Integrates T2 and T3 into `src/main.ts`. Three targeted changes:

**Change 1 — Call `openWorkspacePr` after successful claim**

After `claimTask` returns `{ won: true }`, derive the task branch and call
`openWorkspacePr`:
```typescript
const taskBranch = taskBranchName(featureId, task.id);
const { owner, repo } = parseManagementRepoCoords(workspaceLocalPath);
await openWorkspacePr({
  workspaceRoot: workspaceLocalPath,
  featureId, taskId: task.id, branch: taskBranch,
  baseBranch,
  githubToken: process.env.GITHUB_TOKEN ?? "",
  repoOwner: owner, repoName: repo,
});
```
`baseBranch` is resolved from `workspace.yaml` (already available). If
`GITHUB_TOKEN` is empty, emit a `warn_no_github_token` event but do not abort —
the PR open failure is non-fatal for task execution.

`parseManagementRepoCoords` is a thin wrapper that reads the management repo's SSH
URL from `workspace.yaml` and calls `parseGitHubCoords` from T3.

**Change 2 — Handle `branch_blocked_recovery`**

When `claimTask` returns `{ won: false, reason: "branch_blocked_recovery" }`:
1. Emit `task_blocked_recovery_detected` event.
2. Re-read the task YAML (now includes `blocked_context` from prior run).
3. Proceed to `openWorkspacePr` (finds existing open PR or opens new one).
4. Proceed to `generateAgentContext` and `runClaude` as normal — the agent will
   detect `blocked_context` and enter recovery mode via `start-implementation`.

**Change 3 — Derive `taskBranch` consistently**

Replace every reference to `task.branch` used as the management-repo branch name
with `taskBranchName(featureId, task.id)`. `task.branch` is still written by
`claimTask` and can be used as a sanity-check log field, but `taskBranchName`
is the authoritative source.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Import `taskBranchName` from `./paths.js` and `openWorkspacePr`, `parseGitHubCoords` from `./claim/open-workspace-pr.js`.
- [ ] Add `parseManagementRepoCoords(workspaceRoot)` helper in `main.ts`: reads `workspace.yaml`, finds the management repo entry, calls `parseGitHubCoords` on its `github` URL. Throw if not found.
- [ ] After `claimResult.won === true`: derive `taskBranch`, call `openWorkspacePr`. Wrap in try/catch; on failure emit `workspace_pr_failed` and continue (non-fatal).
- [ ] Add branch for `claimResult.reason === "branch_blocked_recovery"`: emit event, re-read task YAML, fall through to `openWorkspacePr` + `generateAgentContext` + `runClaude`.
- [ ] Replace `task.branch` references used as management-repo branch name with `taskBranchName(featureId, task.id)` in the `generateAgentContext` and `runClaude` calls. Keep `task.branch` in log/event payloads for traceability.
- [ ] Run `tsc --noEmit` across the whole project — must pass.
- [ ] Acceptance: `tsc --noEmit` clean; a full activation cycle (bootstrap → eligibility → claim → openWorkspacePr → runClaude) is traceable through the code; `branch_blocked_recovery` path reaches `runClaude` without error.
