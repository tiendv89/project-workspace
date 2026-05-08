# Handoff — agent-workspace-rules

**Feature:** Inject workspace rules and skills into agent containers at task-claim time
**Completed:** 2026-04-21
**All tasks:** T1 (1/1) done

---

## What was built

Fixed two gaps that caused agents running inside Docker containers to operate without workspace rules or clean skill state.

### Problems solved

| Gap | Before | After |
|---|---|---|
| Workspace rules | `~/.claude/CLAUDE.md` never populated — agents ignored commit identity rules, no-GPG rules, no-`gh`-CLI rules | Workspace `CLAUDE.md` copied to `~/.claude/CLAUDE.md` before every Claude invocation |
| Skill pollution | Skills symlinked into `taskRepoRoot/.claude/skills/` — showed as untracked files in `git status`; risk of agents committing workflow infrastructure into product repos | Skills copied to `~/.claude/skills/` (global) — implementation repo working tree never touched |
| Stale skills | Skills from a prior task or workspace persisted on the container filesystem | `~/.claude/skills/` fully cleaned before each copy — stale entries cannot survive between tasks |

### New and changed components

| File | Repo | Change |
|---|---|---|
| `src/loop/run-claude.ts` | `workflow` | Replaced `setupSkillSymlinks` with `setupGlobalSkills`; added `copyWorkspaceClaude`; both called before Claude subprocess spawns |

### `copyWorkspaceClaude`

Reads `<workspaceRoot>/CLAUDE.md` and writes it to `~/.claude/CLAUDE.md`, creating `~/.claude/` if absent. Overwrites unconditionally — the correct workspace is always known at claim time. If `CLAUDE.md` is missing, emits `workspace_claude_md_missing` (non-fatal) and continues.

### `setupGlobalSkills`

Replaces the old `setupSkillSymlinks`. Runs five steps on every invocation:
1. **Clean** — delete all entries under `~/.claude/skills/`
2. **Copy technical skills** — `workflowLocalPath/technical_skills/*` → `~/.claude/skills/`
3. **Copy workflow skills** — `workflowLocalPath/workflow_skills/*` → `~/.claude/skills/`
4. **Copy workspace-local skills** — non-symlink dirs from `<workspaceRoot>/.claude/skills/` → `~/.claude/skills/` (workspace-local skills take precedence; symlinks skipped — already covered by steps 2–3)
5. **Emit** `skills_setup_complete` with counts: `workflow_skills`, `technical_skills`, `workspace_local_skills`

Copy errors are logged as `skill_copy_warn` and never abort the run.

### Execution point

Both functions run inside `runClaude()` immediately before the Claude subprocess is spawned. This covers both implementation runs and reviewer runs dispatched via `dispatch-draft-review.ts`. No interface changes — `workspaceRoot` and `workflowLocalPath` were already `RunClaudeOpts` parameters.

### Additional changes in PR #46

The PR also added the `CLAUDE_AGENT_RUNTIME=1` environment marker (injected into the Claude subprocess env) and the no-direct-push-to-main rule in `CLAUDE.md`. These were bundled with T1 as closely related runtime hardening.

---

## Operational notes

### No migration required

The change is purely additive inside `run-claude.ts`. Existing containers need no changes beyond pulling the updated image.

### Dependency

Requires `WORKSPACE_ROOT` to be set in the agent environment so `workspaceRoot` resolves correctly. This was already a required env var before this feature.

### Skills directory layout

After this change, Claude's global skill directory `~/.claude/skills/` is fully managed by the runtime. Do not manually place files there — they will be wiped on the next task claim.

---

## Key design decisions

**D1 — Copy to `~/.claude/` not `taskRepoRoot/.claude/`:**
Putting anything in the task repo's working tree risks it being committed to product code. The global home directory is the only safe target inside a container.

**D2 — Overwrite unconditionally on each claim:**
One container may service multiple workspaces sequentially. Always overwriting ensures the agent sees the correct rules for the current task, not a stale copy from a prior workspace.

**D3 — Clean before copy (not merge):**
Merging skill directories across runs would let removed or renamed skills accumulate silently. A clean wipe guarantees the agent sees exactly the skills the current workspace declares.

**D4 — Skip symlinks in workspace `.claude/skills/`:**
Workspace skill directories typically contain symlinks into the workflow repo. Copying the symlink targets directly (steps 2–3) means the symlinks themselves would be redundant and could create duplicates or confusion.

---

## What is NOT done (out of scope)

- **Selective skill loading** (only `### Required skills` listed in task) — all skills are copied; selective loading is a future optimisation.
- **Hot-swap during task** — rules and skills are applied once at claim time; mid-task changes are not picked up until the next claim.
- **Multi-workspace merge** — if a task spans workspaces (not currently supported), only one workspace's `CLAUDE.md` would be active.

---

## PR delivered

| Task | Repo | PR |
|---|---|---|
| T1 — Replace setupSkillSymlinks; add copyWorkspaceClaude | workflow | [#46](https://github.com/tiendv89/agent-workflow/pull/46) — merged 2026-04-21 |
