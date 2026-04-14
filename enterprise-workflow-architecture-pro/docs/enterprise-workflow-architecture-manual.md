# Enterprise Workflow Architecture Manual

## High-level design approach

### Why this system exists
Modern engineering teams want to increase implementation throughput without losing control over quality, architecture, and release safety. The core motivation behind this workflow is to let **humans stay responsible for judgment-heavy work** while allowing **agents to participate later in implementation-heavy work**.

This means:
- humans define scope
- humans approve design
- humans review and validate outcomes
- implementation work can later be delegated to agents when the workflow is ready

The workflow is designed so the organization can become more agent-capable **without rebuilding its operating model every time**.

### Core problem being solved
Without a shared workflow architecture, teams usually end up with:
- feature state spread across chat, tickets, and repos
- implicit approvals
- inconsistent task structure
- unclear execution ownership
- hard-to-audit delivery history
- no stable place for agents to plug in later

This architecture solves that by introducing a **workspace control plane**:
- one place for feature state
- deterministic workflow stages
- explicit approvals and rejections
- machine-readable tasks
- reusable shared skills
- project-local flexibility without forking the company process

### Human / agent operating philosophy
This system intentionally separates responsibilities.

Humans own:
- product decisions
- architecture decisions
- approval and rejection
- review and validation
- release confidence

Agents are treated as external future workers that may later help with:
- implementation
- repo inspection
- code changes
- PR preparation
- moving work into review

The system is intentionally designed so that **agents do not define the workflow**. They consume it.

### What “workflow-first” means
This package focuses on workflow architecture, not agent runtime implementation.

That means the priority is:
1. define the company operating model
2. define files and state transitions
3. define shared skills and templates
4. define how projects consume them
5. only then plug agents into that stable model

This is safer than building agents first and trying to retrofit governance later.

## Executive summary

The current enterprise design is built around one shared canonical root:

`<WORKSPACE_ROOT>/.claude/`

This shared root contains:
- shared workflow rules
- shared workflow skills
- shared templates
- shared schemas
- shared helper scripts

Each project then keeps:
- its own `CLAUDE.md`
- its own `workspace.yaml`
- its own `.env`
- its own feature artifacts
- a real `.claude/skills/` folder containing **per-skill symlinks** to shared skills

Key updates reflected in this version:
- no separate `.workflow/` root
- no whole-directory `skills` symlink
- tasks are stored as **one YAML file per task**
- subtasks live inside task files as checklist/log entries
- `resolve-project-env` is the shared environment-resolution contract
- git transport auth and GitHub API auth are modeled separately
- agents are external future workers, not embedded runtime logic in this package

## Shared root architecture

The company workflow now has one canonical shared root:

`<WORKSPACE_ROOT>/.claude/`

It contains:
- `CLAUDE.shared.md`
- `skills/`
- `templates/`
- `schemas/`
- `scripts/`

Why this matters:
- workflow rules stay centralized
- templates stay aligned
- projects do not fork the company process by accident
- upgrades become easier

## Project workspace model

Each project workspace contains:
- `CLAUDE.md`
- `workspace.yaml`
- `.env`
- `docs/overview.md`
- `docs/features/<feature_id>/...`
- `.claude/skills/` as a **real directory**

Important rule:
- `<project>/.claude/skills/` must remain a real directory
- shared skills are symlinked one by one
- local project-only skills remain possible

Project `CLAUDE.md` should be structured as:
1. project local context
2. shared workflow rules section
3. project-specific additional rules

This gives:
- company-wide consistency
- project-local flexibility
- safe sync behavior

## Lifecycle and governance

### Feature lifecycle
Features follow:
- `in_design`
- `in_tdd`
- `ready_for_implementation`
- `in_implementation`
- `in_handoff`
- `done`
- `blocked`
- `cancelled`

### Task lifecycle
Tasks follow:
- `todo`
- `ready`
- `in_progress`
- `blocked`
- `in_review`
- `done`
- `cancelled`

### Standard workflow
1. Product owner produces `product-spec.md`
2. Human approves or rejects product spec
3. Tech lead produces `technical-design.md`
4. Human approves or rejects technical design
5. Task breakdown is produced as one YAML file per task
6. Human approves or rejects tasks
7. Teams execute tasks in implementation repos
8. Handoffs are recorded
9. Human approves final handoff

### Definition of done
A task should become `done` only when:
- implementation is complete
- review is complete
- PR is approved/merged as required
- a human confirms completion

Agents may move work to `in_review`, but not to `done`.

## Skill system

Current common shared workflow skills:
- `init-workspace`
- `init-feature`
- `sync-workspace-rules`
- `plan-first`
- `list-features`
- `list-global-features`
- `resume-feature`
- `approve-feature`
- `reject-feature`
- `set-feature-stage`
- `start-implementation`
- `resolve-project-env`
- `pr-self-review`
- `pr-create`
- `generate-deployment-checklist`

### Bootstrap model
Bootstrap:
- install shared root
- run `install.sh` for the project
- then use normal project skills

### Key contracts
- `init-workspace` creates workspace and invokes `install.sh`
- `sync-workspace-rules` syncs shared rules and repairs per-skill symlinks
- `start-implementation` validates readiness, dependencies, repo mapping, and clean git state
- `resolve-project-env` resolves workflow-relevant env values
- `pr-create` separates git transport auth from GitHub API auth

## Environment and authentication model

Workflow-relevant values must come from project `.env`.

Typical values:
- `WORKSPACE_ROOT`
- `GIT_AUTHOR_NAME`
- `GIT_AUTHOR_EMAIL`
- `GITHUB_ACCOUNT`
- `SSH_KEY_PATH`
- `GH_TOKEN`
- `GITHUB_TOKEN`

### Two auth modes

#### Git transport auth
Used for:
- clone
- fetch
- pull
- push

Resolved from:
- `SSH_KEY_PATH`

#### GitHub API auth
Used for:
- automatic PR creation
- GitHub API operations

Resolved from:
- `GH_TOKEN`
- `GITHUB_TOKEN`

Rule:
- do not assume SSH is sufficient for PR creation

### Manual fallback
If no API token exists:
- generate manual PR URL
- record `manual_required`
- do not pretend PR was created

## Agent integration model

This package is workflow-first.

It does **not** define agent runtime implementation now.

Agents are treated as future external workers that will join the workflow later.

Later, agents may read:
- `workspace.yaml`
- feature status files
- task YAML files
- shared workflow rules
- project `.env` via `resolve-project-env`

Later, agents may mutate:
- task status:
  - `ready -> in_progress`
  - `in_progress -> in_review`
  - `in_progress -> blocked`
- PR metadata
- task logs

Agents may not mutate:
- stage approvals
- final `done` decision
- handoff approval

## Operations and upgrade model

Recommended bootstrap sequence:
1. install shared root at `<WORKSPACE_ROOT>/.claude/`
2. create or upgrade project workspace
3. run `<WORKSPACE_ROOT>/.claude/scripts/install.sh <project_root>`
4. sync shared workflow rules
5. begin normal project operation

Why `install.sh` matters:
- before project skill links exist, project-level shared skills cannot repair themselves
- `install.sh` is the bootstrap path
- `sync-workspace-rules` is the normal sync/repair path after bootstrap

### Additive evolution rule
Prefer:
- new shared sections
- explicit migration notes
- upgrade packs
- preserving current semantics

Avoid:
- silently changing workflow meaning
- replacing whole project files without warning
- hardcoding assumptions that break existing projects