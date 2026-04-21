# Technical Design

## Feature
- Feature ID: `agent-workspace-rules`
- Title: Inject workspace rules and skills into agent containers at task-claim time

## Current State

### Skills — partially wired, wrong target

`run-claude.ts` already calls `setupSkillSymlinks()` (lines 117–152) before spawning Claude. It creates **symlinks** in `taskRepoRoot/.claude/skills/` from three sources:
1. `workspaceRoot/.claude/skills/`
2. `workflowLocalPath/workflow_skills/`
3. `workflowLocalPath/technical_skills/`

This works when Claude runs from `taskRepoRoot` as CWD — Claude Code reads `.claude/skills/` from the project root. However:
- Symlinks point to paths inside the container that must already exist (fragile if mounts change)
- Skill state is not cleaned between task runs — stale/removed skills persist
- Skills are scoped to the task repo dir, not available globally

### CLAUDE.md — not wired at all

There is no code anywhere that copies the workspace `CLAUDE.md` to `~/.claude/CLAUDE.md` inside the container. Workspace rules (commit identity, no co-authorship, no GPG signing, no `gh` CLI) are completely invisible to Claude.

## Chosen Design

Both changes land in `run-claude.ts`, inside `runClaude()`, immediately before the Claude subprocess is spawned. This is the single point where `workspaceRoot` and `workflowLocalPath` are both available.

### Change 1 — Copy `CLAUDE.md` to `~/.claude/CLAUDE.md`

```
copyWorkspaceClaude(workspaceRoot: string): void
```

- Read `<workspaceRoot>/CLAUDE.md`
- Write to `~/.claude/CLAUDE.md` (create `~/.claude/` if absent)
- Overwrite unconditionally — the correct workspace is always known at this point
- If `CLAUDE.md` is missing from the workspace, skip silently and emit `workspace_claude_md_missing` event (non-fatal)

### Change 2 — Replace `setupSkillSymlinks` with `setupGlobalSkills`

Remove `setupSkillSymlinks` and replace with a new function:

```
setupGlobalSkills(workspaceRoot: string, workflowLocalPath: string): void
```

**Step 1 — Clean `~/.claude/skills/`**
Delete all entries under `~/.claude/skills/` (recursive). This ensures stale skills from a prior task or workspace don't persist.

**Step 2 — Copy `workflowLocalPath/technical_skills/*`**
For each directory entry under `technical_skills/`, copy the whole directory into `~/.claude/skills/<entry>`.

**Step 3 — Copy `workflowLocalPath/workflow_skills/*`**
Same as Step 2 for `workflow_skills/`.

**Step 4 — Copy non-symlink dirs from `workspaceRoot/.claude/skills/*`**
For each entry under `workspaceRoot/.claude/skills/`:
- Skip if it is a symlink (already covered by Steps 2–3 above)
- Skip `.gitignore`
- Copy the directory into `~/.claude/skills/<entry>`, overwriting if already present (workspace-local skills take precedence)

**Step 5 — Emit `skills_setup_complete` event** with counts: `workflow_skills`, `technical_skills`, `workspace_local_skills`.

Errors in any copy are logged as `skill_copy_warn` but never abort the run.

### Execution point in `runClaude`

```
// Before spawning Claude (after preflight, replacing setupSkillSymlinks):
copyWorkspaceClaude(workspaceRoot);
setupGlobalSkills(workspaceRoot, workflowLocalPath);

// Claude spawn follows immediately after.
```

Both run on every `runClaude` invocation — which covers both implementation runs and review runs dispatched via `dispatch-draft-review.ts`.

## Files changed

| File | Change |
|---|---|
| `src/loop/run-claude.ts` | Replace `setupSkillSymlinks` with `setupGlobalSkills`; add `copyWorkspaceClaude`; call both before spawn |

## Dependency Analysis

- No new dependencies — uses Node.js `fs` (already imported) and `os.homedir()` (stdlib)
- `workspaceRoot` and `workflowLocalPath` are already parameters of `RunClaudeOpts` — no interface changes needed

## Parallelization / Blocking Analysis

Single task. No parallelization needed.
