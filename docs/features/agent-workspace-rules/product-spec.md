# Product Specification

## Feature
- Feature ID: `agent-workspace-rules`
- Title: Inject workspace rules and skills into agent containers at task-claim time

## Problem

Agents running inside Docker containers do not inherit workspace-level rules or skills. Two gaps exist:

### Gap 1 — Rules not loaded

Claude Code reads its global config from `~/.claude/CLAUDE.md` inside the container, but this file does not exist by default — so rules such as:

- Commit identity (`user.name`, `user.email`)
- No Claude co-authorship trailers in commit messages
- No GPG signing
- No `gh` CLI usage (use `pr-create` instead)

...are unknown to the agent. It may produce commits with the wrong author, GPG-signed with the wrong key, or attempt to use `gh pr create` instead of the workspace's `pr-create` skill.

### Gap 2 — Skills not loaded

Skills live in `<workspace>/.claude/skills/` (symlinked from `workflow/`). When Claude is spawned against an **implementation repo** as its working directory, that repo has no `.claude/skills/` directory — so all workflow and technical skills are invisible to the agent. The `### Required skills` section in `tasks.md` is never honoured.

## Why not write CLAUDE.md into each implementation repo?

That approach requires touching every implementation repo's codebase and keeping those files in sync as rules evolve. Rules are workspace-owned, not repo-owned.

## Why not copy at container bootstrap?

The agent runtime watches multiple workspaces. At bootstrap time, it does not yet know which workspace a given task belongs to. The correct workspace is only known at task-claim time.

## Goals

### CLAUDE.md — workspace rules

Each time the agent runtime **claims a task**, before invoking Claude:
1. Identify the workspace the task belongs to.
2. Copy `<workspace>/CLAUDE.md` → `~/.claude/CLAUDE.md` inside the container.

Rules are always correct for the workspace being worked on, regardless of how many workspaces the container watches.

### Skills — global skill directory

Each time the agent runtime claims a task (implementation start or review start), before invoking Claude:
1. Clean `~/.claude/skills/`.
2. Copy `$WORKSPACE_ROOT/workflow/technical_skills/*` → `~/.claude/skills/`.
3. Copy `$WORKSPACE_ROOT/workflow/workflow_skills/*` → `~/.claude/skills/`.
4. Copy any **non-symlink** directories from `<workspace>/.claude/skills/` → `~/.claude/skills/` (these are workspace-local skills not present in the workflow dirs).

Symlinked entries in `<workspace>/.claude/skills/` are skipped — they are already covered by the workflow dirs copied in steps 2–3.

Clean + re-copy on every task start and review start to ensure a consistent, up-to-date state.

Claude Code discovers skills natively from `~/.claude/skills/` — no parsing of `tasks.md`, no content injection into `CLAUDE.md` required.

## Non-goals

- Selectively loading only the skills listed under `### Required skills` — copying all skills is simpler and has no meaningful cost.
- Hot-swapping rules or skills mid-task — the copy happens once per claim, before Claude is invoked.
- Merging rules from multiple workspaces — one task, one workspace, one `CLAUDE.md`.
- Replacing per-repo `CLAUDE.md` — per-repo files remain valid for repo-specific rules.
