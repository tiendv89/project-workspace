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

### Gap 2 — Skills pollute the task repo working tree

The agent runtime already creates skill symlinks inside `taskRepoRoot/.claude/skills/` before spawning Claude, so skills are technically discoverable. However, this approach has a critical flaw: the symlinks are created **inside the implementation repo's working tree**. They appear as untracked files in `git status`, and an agent following commit instructions could accidentally commit `.claude/skills/` to a product repo — leaking workflow infrastructure into implementation code.

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

### Skills — move to global skill directory

Each time the agent runtime claims a task (implementation start or review start), before invoking Claude:
1. Clean `~/.claude/skills/` — removes any stale skills from a prior task or workspace.
2. Copy `$WORKSPACE_ROOT/workflow/technical_skills/*` → `~/.claude/skills/`.
3. Copy `$WORKSPACE_ROOT/workflow/workflow_skills/*` → `~/.claude/skills/`.
4. Copy any **non-symlink** directories from `<workspace>/.claude/skills/` → `~/.claude/skills/` (workspace-local skills not present in the workflow dirs; these take precedence).

Symlinked entries in `<workspace>/.claude/skills/` are skipped — already covered by steps 2–3.

This replaces the current approach of symlinking into `taskRepoRoot/.claude/skills/`. Skills remain discoverable by Claude (via `~/.claude/skills/` global lookup) while the implementation repo's working tree stays clean.

## Non-goals

- Selectively loading only the skills listed under `### Required skills` — copying all skills is simpler and has no meaningful cost.
- Hot-swapping rules or skills mid-task — the copy happens once per claim, before Claude is invoked.
- Merging rules from multiple workspaces — one task, one workspace, one `CLAUDE.md`.
- Replacing per-repo `CLAUDE.md` — per-repo files remain valid for repo-specific rules.
