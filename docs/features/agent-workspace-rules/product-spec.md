# Product Specification

## Feature
- Feature ID: `agent-workspace-rules`
- Title: Inject workspace rules into agent containers at task-claim time

## Problem

Agents running inside Docker containers do not inherit workspace-level rules. Claude Code reads its global config from `~/.claude/CLAUDE.md` inside the container, but this file does not exist by default — so rules such as:

- Commit identity (`user.name`, `user.email`)
- No Claude co-authorship trailers in commit messages
- No GPG signing
- No `gh` CLI usage (use `pr-create` instead)

...are unknown to the agent. It may produce commits with the wrong author, GPG-signed with the wrong key, or attempt to use `gh pr create` instead of the workspace's `pr-create` skill.

## Why not write CLAUDE.md into each implementation repo?

That approach requires touching every implementation repo's codebase and keeping those files in sync as rules evolve. Rules are workspace-owned, not repo-owned — they belong in the workspace config, not scattered across repos.

## Why not copy at container bootstrap?

The agent runtime watches multiple workspaces. At bootstrap time, it does not yet know which workspace a given task will belong to. Copying at bootstrap would require either:
- Picking one workspace arbitrarily, or
- A shared global file that gets overwritten when the next task from a different workspace is claimed

Both are wrong.

## Goals

1. Each time the agent runtime **claims a task**, it identifies the workspace the task belongs to and copies `<workspace>/CLAUDE.md` → `~/.claude/CLAUDE.md` inside the container before invoking Claude.
2. Rules are always correct for the workspace being worked on, regardless of how many workspaces the container watches.
3. No separate rules file to maintain — `CLAUDE.md` is already the authoritative source of workspace rules.
4. No changes required to implementation repos.

## Non-goals

- Hot-swapping rules mid-task — the copy happens once per claim, before Claude is invoked.
- Merging rules from multiple workspaces — one task, one workspace, one `CLAUDE.md`.
- Replacing per-repo `CLAUDE.md` entirely — per-repo files remain valid for repo-specific rules; this feature covers workspace-level cross-cutting rules only.
