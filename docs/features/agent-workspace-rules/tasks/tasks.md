# Tasks — agent-workspace-rules

## T1: Replace setupSkillSymlinks with setupGlobalSkills; add copyWorkspaceClaude

**Repo**: `workflow`
**File**: `src/loop/run-claude.ts`

### What to do

1. **Remove `setupSkillSymlinks()`** — delete the function entirely. It must no longer create any files or symlinks inside `taskRepoRoot`.

2. **Add `copyWorkspaceClaude(workspaceRoot: string): void`**
   - Source: `<workspaceRoot>/CLAUDE.md`
   - Destination: `~/.claude/CLAUDE.md` (use `os.homedir()` to resolve `~`)
   - Create `~/.claude/` if it does not exist (`mkdirSync` with `recursive: true`)
   - Overwrite unconditionally
   - If source file is missing: emit `workspace_claude_md_missing` event and return (non-fatal)

3. **Add `setupGlobalSkills(workspaceRoot: string, workflowLocalPath: string): void`**
   - Step 1: Clean `~/.claude/skills/` — `rmSync` recursive if it exists, then `mkdirSync` recursive
   - Step 2: Copy all dirs from `<workflowLocalPath>/technical_skills/` → `~/.claude/skills/`
   - Step 3: Copy all dirs from `<workflowLocalPath>/workflow_skills/` → `~/.claude/skills/`
   - Step 4: For each entry in `<workspaceRoot>/.claude/skills/`: skip symlinks and `.gitignore`; copy remaining dirs → `~/.claude/skills/` (overwrite — workspace-local skills take precedence)
   - Step 5: Emit `skills_setup_complete` with counts `{ technical_skills, workflow_skills, workspace_local_skills }`
   - Individual copy errors: emit `skill_copy_warn` and continue (non-fatal)

4. **Update `runClaude()`** — replace the `setupSkillSymlinks(...)` call with:
   ```ts
   copyWorkspaceClaude(workspaceRoot);
   setupGlobalSkills(workspaceRoot, workflowLocalPath);
   ```

5. **Update tests** in `tests/run-claude.test.ts`:
   - Remove tests that assert symlinks are created in `taskRepoRoot/.claude/skills/`
   - Add tests for `copyWorkspaceClaude`: CLAUDE.md present → written to `~/.claude/CLAUDE.md`; missing → emits event, no error
   - Add tests for `setupGlobalSkills`: skills copied from all three sources; stale skills cleaned; symlinks in workspace skills dir skipped

6. **Update `CLAUDE.shared.md`** — add a rule under the Management repo section:
   - No direct push to main on the management repo for **any** reason — feature docs, task state, skill updates, or otherwise.
   - `init-feature` and all workflow skills that write to the management repo must create a feature branch and open a PR to base branch.
   - The only exception is the very first workspace initialisation commit (`init-workspace`).

### Required skills
