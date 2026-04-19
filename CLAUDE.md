# Workspace operating guide

This directory is a project-management workspace, not an implementation repository.

## Project local context
- Project name: workspace
- Project purpose: <describe the purpose of this workspace>

<!-- BEGIN SHARED WORKFLOW RULES -->
# Shared workflow rules

## Feature lifecycle

Features follow this lifecycle:

- in_design
- in_tdd
- ready_for_implementation
- in_implementation
- in_handoff
- done
- blocked
- cancelled

![Feature Lifecycle Workflow](docs/feature-workflow.png)

## Stage review status values

- draft
- awaiting_approval
- approved
- rejected

## Task status values

- todo
- ready
- in_progress
- blocked
- in_review
- done
- cancelled

## Workflow

1. Product owner produces `product-spec.md`
2. Human approves or rejects product spec
3. Tech lead uses `tech-lead` (Phase 1) to produce `technical-design.md`
4. Human approves or rejects technical design
5. Tech lead uses `tech-lead` (Phase 2) to produce task breakdown under `docs/features/<feature_id>/tasks/`
6. Human approves or rejects tasks
7. Teams execute tasks in their real implementation repos
8. Handoffs are recorded under `handoffs/`
9. Human approves final handoff

## Task structure rules

- Tasks are stored as one YAML file per task under `docs/features/<feature_id>/tasks/`
- Subtasks are recorded inside the parent task file as checklist/log entries
- Subtasks do not have their own lifecycle status
- Task lifecycle status exists only at the task file level
- One task changes one repository only
- `repo` must match `workspace.yaml -> repos[].id`
- Every task must define:
  - `status`
  - `depends_on`
  - `execution.actor_type`
  - `branch`

## Task status transition rules

Valid transitions only — skipping a step is a rule violation:

```
todo → ready        (auto-ready rule, applied by whoever marks the last dependency done)
ready → in_progress (start-implementation only)
in_progress → in_review  (agent or human, after work is complete)
in_progress → blocked    (agent, when blocked)
in_review → done    (human only)
in_review → ready   (human, when rejecting for rework)
blocked → ready     (human, after resolving the block)
any → cancelled     (human only)
```

- `todo → in_progress` is **never valid** — a task must pass through `ready` first.
- `start-implementation` must hard-stop if the task status is not `ready`.

![Task Status Workflow](docs/task-workflow.png)

## Task log rules

- Every task state change should be recorded in the task file `log`
- Both humans and agents append task log entries when they mutate task state
- Marking a task `done` requires a human log entry
- **Timestamp rule**: every log entry `at:` field must use a real local timestamp with timezone offset obtained at the time of the action via `date +%Y-%m-%dT%H:%M:%S%z`. Hardcoded or placeholder timestamps (e.g. `00:00:00Z`) are not acceptable.

## Task file scope

An agent executing task T_x must only write to `T_x.yaml` in the management repo. Writing to any other task file (`T_y.yaml` where y ≠ x) is forbidden — even for valid reasons such as schema migrations, audit entries, or bulk updates.

Cross-cutting changes to multiple task files must be:
- Planned as a dedicated task with a single executor.
- Executed with no concurrent runners touching any of the affected files.

This rule preserves the concurrency model: each task YAML is an independent, contention-free write target. The moment an agent writes to a sibling task file, that guarantee breaks.

## Dependency rules

- Every task must define `depends_on` (use `[]` if none)
- A task can only start when:
  - its status is `ready`
  - all tasks in `depends_on` are `done`
- This rule is enforced by `start-implementation`
- **Auto-ready rule**: when a task is marked `done`, any task whose entire `depends_on` list is now satisfied must have its status advanced from `todo` to `ready`. The actor who marks the dependency `done` is responsible for applying this transition and appending a log entry to each affected task.

## Execution rules

Each task must define:

```yaml
execution:
  actor_type: human | agent | either
```

## Review boundary

- Agents may move work to `in_review`
- Humans review, validate, and decide whether work becomes `done`
- Agents do not approve stages
- Agents do not mark tasks `done`

## Start rule

- Tasks marked `ready` are eligible for execution
- Execution must begin through `start-implementation`

## Skill execution contract

When a workflow skill declares an autonomous execution contract — any instruction such as "do not stop after X", "proceed directly", "all steps are part of a single invocation", or "without pausing for human confirmation" — the agent must honour that contract in full:

- Complete every declared step in sequence without pausing or returning control to the user between steps.
- Do not stop after setup phases (branch creation, environment resolution, log entry) and wait for a prompt.
- Do not treat a partial completion (e.g. implementation only, branch setup only) as a finished invocation.
- If a blocking issue arises that cannot be resolved, set `status: blocked`, write `blocked_reason`, and stop — do not silently drop remaining steps.

Stopping early and waiting for the user to continue is a **contract violation** regardless of whether any individual step succeeded.

## Reset / rollback rule

- Stage resets preserve artifacts
- Downstream artifacts are marked for revalidation, not deleted

## Environment resolution rules

- Before any repo operation, the operator or agent must read the project `.env` file if it exists.
- Workflow-relevant environment values should be resolved from the project `.env` first.
- If a required value is missing from `.env`, the workflow must ask the user instead of guessing.

## Required environment values

Typical required values:

- `WORKSPACE_ROOT`
- `GIT_AUTHOR_NAME`
- `GIT_AUTHOR_EMAIL`
- `GITHUB_ACCOUNT`
- `SSH_KEY_PATH`

## Figma MCP usage rule

When `FIGMA_PERSONAL_ACCESS_TOKEN` is present in the project `.env` and `figma-mcp` is listed under the role's `enabled_skills`, agents must use the Figma MCP to read design context before implementing any UI.

- Read the target Figma frame or component via the MCP **before** writing code.
- Extract design tokens (colors, spacing, typography) from Figma variables — do not hardcode values that exist in Figma.
- Derive component and prop names from the Figma component name.
- If `FIGMA_PERSONAL_ACCESS_TOKEN` is missing, stop and ask the user to add it to `.env` (see `.env.template`).
- Never skip Figma context when the token is available — guessing at design values is not acceptable.

## Management repo

The management repo is the repository that stores the workspace's feature docs, task YAML files (`docs/features/<feature_id>/tasks/`), and `CLAUDE.md`. It is the authoritative record of task state and is separate from (or may overlap with) implementation repos.

Rules:
- Every workspace must declare exactly one management repo in `workspace.yaml` via `management_repo: <repo_id>`, where the value matches a `repos[].id` entry.
- The management repo is a required field. Workflow skills that operate on task state must resolve it before proceeding.
- **Claim commit rule**: before an agent begins implementation work in a target repo, it must commit and push the claim (status change to `in_progress` in `T_x.yaml`) to the management repo on the task's feature branch. If the push is rejected (non-fast-forward), the agent must stop — another agent won the claim.
- The management repo commit is the canonical record of task ownership. Without it, the claim is not valid and the agent must not proceed with implementation.
- Agents may only modify their own task file (`T_x.yaml`) in the management repo. See "Task file scope" rule.
- **Branch merge rule**: when the human marks a task `done`, they must also open a PR on the management repo to merge the task's feature branch into `main`. This keeps `main` up-to-date with all terminal task states and prevents task state from living only on feature branches indefinitely. The `done` log entry and the management repo merge PR must happen together.
- **No direct push to main rule**: agents must never commit task state changes (status updates, log entries) directly to `main` on the management repo. All task state mutations must be committed to the task's feature branch (`feature/<feature_id>-<work_id>`). If the feature branch does not exist yet, the agent must create it before committing. Pushing directly to `main` is a rule violation even when no feature branch was previously created by `start-implementation`.
- **Dependency unblock rule**: whenever a task is marked `done`, immediately check every other task in the same feature whose `depends_on` list includes the just-completed task. For each such task where all `depends_on` entries are now `done`, transition its status from `todo` to `ready` and append a `ready` log entry. This must happen in the same commit as the `done` update.
- **Task branch rule**: every commit to the management repo during task execution must land on the task's feature branch, not on `main`. Before committing, follow the **branch checkout + sync protocol** below. This rule applies to all management repo writes during a task — claim commits, status updates, log entries, and log file flushes.

## Branch checkout + sync protocol

This protocol applies before any commit to **both the management repo and implementation repos** during task execution. Run it whenever switching to or working on a feature branch.

### Step 1 — Ensure you are on the feature branch

```bash
git fetch origin
git checkout <feature-branch>   # create from main if it doesn't exist yet
```

If the branch does not exist locally or on origin, create it from the latest `main`:

```bash
git checkout main && git pull origin main
git checkout -b <feature-branch>
```

### Step 2 — Pull latest from origin

```bash
git pull origin <feature-branch>
```

If the pull succeeds (fast-forward or clean merge), continue.

### Step 3 — Handle a failed pull (force-push or diverged history)

If `git pull` is rejected because the origin branch has diverged (e.g. another agent force-pushed or rewound the branch), follow this recovery sequence:

1. **Save local changes** — capture everything this agent added on top of the base branch:
   ```bash
   git diff origin/main..HEAD > /tmp/<task-id>-local.patch
   git log origin/main..HEAD --oneline > /tmp/<task-id>-local-commits.txt
   ```
2. **Reset to main** and delete the stale local branch:
   ```bash
   git checkout main
   git branch -D <feature-branch>
   ```
3. **Re-checkout** the branch from origin:
   ```bash
   git checkout -b <feature-branch> origin/<feature-branch>
   ```
4. **Compare and merge** — diff the saved patch against the new branch state:
   ```bash
   git diff HEAD /tmp/<task-id>-local.patch
   ```
   - If the origin branch already contains the same work, discard the patch and continue.
   - If the work differs, apply the patch (`git apply /tmp/<task-id>-local.patch`), resolve any conflicts, and commit.

### Step 4 — Rebase onto latest main before committing

```bash
git fetch origin
git rebase origin/main
```

This keeps history linear and prevents merge conflicts when the branch is eventually merged into `main`.

### Scope

This protocol applies to:
- The **management repo** — before every task state write (claim, status update, log entry, log flush).
- **Implementation repos** — before every implementation commit during task execution.

## Git / SSH rules

- Repository operations must use the SSH key configured in project `.env` through `SSH_KEY_PATH`
- Do not assume the default SSH key is correct
- If `SSH_KEY_PATH` is missing, require the user to provide it
- If a repo requires SSH auth, the workflow should use the resolved `SSH_KEY_PATH` explicitly

## Git hard-reset safety rule

Before running `git reset --hard`, `git checkout --force`, or any other destructive
git operation on a repo, the agent **must** run both checks below and **hard-stop**
if either fails:

1. **Uncommitted changes check** — `git status --short`. If output is non-empty
   (staged, unstaged, or untracked tracked files), stop. Do not reset.
2. **Unpushed commits check** — `git log origin/<base_branch>..HEAD --oneline`.
   If output is non-empty, stop. Do not reset.

On hard-stop, report the exact output of the failing check and wait for the user to
resolve it (e.g. push, stash, or explicitly confirm discard) before proceeding.

This rule applies to every repo touched in the workflow — implementation repos,
management repos, and the workflow repo itself.

## Test-before-PR rule

- **Always run the full test suite before opening a PR.** This applies to every task, every workflow, every agent context.
- Use whatever test commands the implementation repo specifies — check the README, `package.json`, `Makefile`, `go.mod`, or equivalent build config. Do not assume a specific test runner or language.
- All tests must pass before invoking `pr-create`. Fix any failures and re-run until clean.
- Do not open a PR for failing tests.

## PR creation rule

- **Do not use `gh` CLI to create pull requests.** Use the `pr-create` skill instead.
- `pr-create` uses the GitHub REST API via `curl` with `GITHUB_TOKEN` from project `.env` — this avoids requiring `gh` to be installed on the host or in agent containers.
- Any workflow skill or agent that needs to open a PR must invoke `pr-create` rather than calling `gh pr create` directly.
- `GITHUB_TOKEN` is required in project `.env` for PR creation. If missing, `pr-create` falls back to `~/.config/gh/hosts.yml`.

## PR title convention

PR titles must follow the format:

```
<type>(<featureId>/T<n>): <short description>
```

Examples:
- `feat(task-branch-lifecycle/T1): taskBranchName helper + BlockedContext schema`
- `fix(agent-runtime-hardening/T3): correct Dockerfile claude CLI install path`

Rules:
- `<type>` follows conventional commits (`feat`, `fix`, `chore`, `refactor`, `docs`, etc.)
- `<featureId>` is the feature directory name under `docs/features/`
- `T<n>` is the task ID
- Description is lowercase, imperative, no trailing period
- Keep the full title under 72 characters

## Shared environment resolution rule

- Workflow skills that perform repo, git, PR, or SSH-related work must use `resolve-project-env`
- `resolve-project-env` is the shared contract for reading project `.env`
- Required values must be resolved from project `.env` first
- If required values are missing, the workflow must ask the user explicitly instead of guessing

## SSH rule

- SSH-based git access must use `SSH_KEY_PATH` resolved through `resolve-project-env`
- Do not assume the default SSH key is correct

## Per-task required skills

Technical skills are declared per task, not per agent or per role. Each task's `## T<n>` section in `tasks.md` includes a `### Required skills` subsection listing the skill slugs the task needs. Skill slugs must match directory names under `workflow/technical_skills/`.

At run-task time, the agent reads the declared skills and loads their `SKILL.md` content into its system prompt. This is the only capability-matching mechanism — there is no agent-side role or skills list.

See `tasks.md`'s `### Required skills` subsection as the source of truth for per-task capability.

## Narrative / state split

Task YAML files (`tasks/T<n>.yaml`) contain only machine-mutable state: `status`, `depends_on`, `blocked_reason`, `branch`, `execution`, `pr`, `log`. Agents read and write these files.

Logical intent — description, subtasks, required skills, model overrides — lives in `tasks.md`. This file is authored by humans (or the tech-lead skill) and stays stable during implementation. Agents read it but do not modify it except to check off subtask items.

This split isolates git-push contention: multiple agents can mutate separate task YAMLs in parallel without conflicting on a shared narrative file.

## Product-spec phase write boundary

During the `product_spec` stage, agents must not write or modify any file outside the feature's `product-spec.md`.

If workspace-level changes are discovered as needed (e.g. missing repo entries, config typos, new skills, rule updates), the agent must **stop and list them explicitly for the human** instead of applying them. The human decides whether to apply them before or after the product spec is approved.

Examples of changes that must be surfaced, not applied:
- Edits to `workspace.yaml`, `CLAUDE.md`, `.env`, `.env.template`
- Creating or modifying skills under `technical_skills/`
- Registering new repos or roles
- Any file outside `docs/features/<feature_id>/product-spec.md`

## CLAUDE.md edit policy

Before editing `CLAUDE.md` in any project workspace, determine whether the change is **workspace-specific** or **common**.

### Common change
A rule that should apply to every workspace using this workflow (e.g. lifecycle rules, task structure, git conventions, environment resolution).

**Do not edit `CLAUDE.md` directly.**

Instead:
1. Edit `$WORKSPACE_ROOT/CLAUDE.shared.md`
2. Run `sync-workspace-rules` to propagate the change into `CLAUDE.md`

### Workspace-specific change
A rule that only applies to this one project (e.g. repo-specific conventions, stack-specific constraints, local team agreements).

Edit the project-specific section of `CLAUDE.md` directly — the content above or below the shared section markers.

### Uncertain
If it is not clear whether the change is common or workspace-specific, **stop and ask the human** before making any edit.

## Shell command permission policy

The assistant may run read-only inspection commands without asking first when working inside a project repository or workspace.

Examples of allowed read-only commands:

- `pwd`
- `ls`
- `find`
- `grep`
- `rg`
- `cat`
- `head`
- `tail`
- `git status`
- `git branch`
- `git diff --stat`

The assistant must still ask before running commands that:

- modify files
- delete files
- move files
- change permissions
- push to remote
- create or merge branches
- deploy infrastructure or applications
<!-- END SHARED WORKFLOW RULES -->

## Project-specific additional rules
- Add project-specific rules here
- Do not rewrite the shared workflow rules above unless intentionally changing the company model
