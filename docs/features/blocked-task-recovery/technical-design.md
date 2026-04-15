# Technical Design

## Feature
- Feature ID: `blocked-task-recovery`
- Title: Blocked task recovery — artifact preservation and re-entry flow

## Current State

When an agent blocks:
1. Sets `task.status: blocked`, writes `blocked_reason` and `suggested_next_step`
   to the task YAML, appends a log entry, and exits.
2. No code is committed or pushed — the implementation repo is left in whatever
   state the agent left it (dirty working tree, unstaged changes, etc.).
3. The `start-implementation` re-do mode only handles `in_review` tasks
   (PR review comment fixes). There is no re-do path for `blocked` tasks.

The result: the only recovery data is the text in `blocked_reason`.

## Constraints

- Must not break the normal claim flow for `ready` tasks.
- Must not push broken code to `main` — WIP pushes go to the feature branch only.
- The recovery re-entry must be explicit: the human sets the task back to `ready`
  before an agent can re-claim it.
- The `blocked_context` fields added to the task YAML must be optional (not
  required for tasks that have never been blocked).

## Options Considered

### Option A — Push WIP commit + no PR
Agent commits all dirty state under a `wip:` message, pushes to the feature branch,
and exits. No PR opened. The branch exists on remote and is inspectable.

- Pros: simple, non-intrusive, preserves all partial work.
- Cons: dirty/incomplete code is on the remote branch, but labeled clearly as WIP.

### Option B — Open draft PR
Agent opens a draft PR in addition to pushing. Draft PRs are not reviewable for merge
but are discoverable in the GitHub PR list.

- Pros: highly visible, easy to find in GitHub UI.
- Cons: adds noise to the PR queue; draft PR lifecycle is separate from task YAML
  lifecycle; more state to keep in sync.

### Option C — Write `blocked_context.md` artifact to workspace
Agent writes a structured file describing what it tried and where it stopped.

- Pros: human-readable, stored in management repo.
- Cons: doesn't preserve the actual code; requires a separate format to maintain.

## Chosen Design

**Option A** — push a WIP commit, no PR.

The feature branch is already named in the task YAML (`task.branch`). Pushing
a `wip:` commit to it makes the partial work inspectable without polluting the PR
queue. The `blocked_context` sub-object in the task YAML records the branch and
last WIP SHA for the recovering agent to check out.

Draft PR (Option B) can be added later as an optional enhancement if operators
find the branch approach insufficiently visible.

## Chosen Design — detail

### Task YAML additions

```yaml
blocked_context:
  wip_branch: feature/agent-runtime-hardening-T4
  wip_sha: abc1234
  pushed_at: 2026-04-15T14:00:00+0700
```

This sub-object is written only when the agent blocks with partial work to push.
It is cleared (set to `null`) when the task is re-activated and the recovering
agent begins fresh work on top of the WIP commits.

### Agent blocking sequence (new)

1. Detect unresolvable blocker.
2. `git add -A && git commit -m "wip: partial work before block — <blocked_reason summary>"` in the implementation repo.
3. Push the feature branch to remote.
4. Record `blocked_context.wip_sha` (the WIP commit SHA), `wip_branch`, `pushed_at` in the task YAML.
5. Set `status: blocked`, write `blocked_reason` + `suggested_next_step`, append log entry.
6. Push the updated task YAML to the management repo feature branch.
7. Exit.

### Human re-activation sequence

1. Human reads `blocked_reason` and `suggested_next_step`.
2. Human optionally updates `suggested_next_step` to guide the next agent.
3. Human sets `status: ready` in the task YAML and pushes to management repo.
4. (Optional) Human pushes a fix commit to the WIP branch to unblock the agent.
5. Normal claim flow takes over on the next agent activation cycle.

### `start-implementation` blocked re-do mode (new)

Triggered when task `status` is `ready` AND `blocked_context` is non-null
(i.e. there is a prior WIP branch to build on).

Instead of:
```
git checkout <base_branch>
git reset --hard origin/<base_branch>
git checkout -b feature/<id>
```

Do:
```
git fetch origin
git checkout <wip_branch>
git reset --hard origin/<wip_branch>
```

The agent then reads `blocked_reason` and `suggested_next_step` as additional
context before proceeding with implementation.

After successful PR creation in the recovery run, clear `blocked_context` (set to
`null`) in the task YAML.

## Dependency Analysis

- Touches `src/bootstrap/agent-context.ts` (Rules section — update blocked exit rule).
- Touches `workflow_skills/start-implementation/SKILL.md` (new blocked re-do mode).
- Touches task YAML schema (new optional `blocked_context` field).
- No new external dependencies.

## Parallelization / Blocking Analysis

All tasks are sequentially dependent:
- T1 must define the schema changes and the blocking sequence update.
- T2 (start-implementation re-do mode) depends on T1 (schema must be settled first).
- T3 (agent-context.ts rules update + integration test) depends on T2.
