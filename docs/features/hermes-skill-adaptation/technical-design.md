# Technical Design

## Feature
- Feature ID: `hermes-skill-adaptation`
- Title: Hermes Skill Adaptation — Convert workflow and technical skills for Hermes executor

---

## 1. Current State

### Claude executor — how skills are loaded

The Claude executor (`runtime/executors/claude/src/index.ts`) sets up skill context in
three steps before spawning `claude -p`:

1. **`copyWorkspaceClaude(workspaceRoot)`** — copies `CLAUDE.md` from the cloned mgmt
   repo to `~/.claude/CLAUDE.md`. Claude Code CLI auto-injects this file as a system
   prompt on every invocation. It contains the full workspace workflow rules (task
   lifecycle, git conventions, skill execution contract, etc.).

2. **`setupGlobalSkills(workspaceRoot, workflowLocalPath)`** — copies
   `workflow/technical_skills/` and `workflow/workflow_skills/` into
   `~/.claude/skills/`. Claude Code CLI discovers these directories automatically and
   exposes them as slash commands (e.g. `/start-implementation`, `/pr-create`,
   `/rag-context`).

3. **`setupGlobalSettings(workflowLocalPath, emit)`** — copies
   `workflow/templates/claude-settings.json` to `~/.claude/settings.json`, configuring
   tool permissions and MCP servers.

The briefing Claude receives then just says: `Run /start-implementation <taskId>`. The
skill handles the entire flow — read spec, implement, test, open PR, write
`result.json`.

### Hermes executor — current state (broken)

The Hermes executor (`runtime/executors/hermes/src/index.ts`) spawns:

```
hermes chat --query <briefing> --quiet --ignore-rules
```

`--ignore-rules` disables **all** of Hermes's native context-loading mechanisms:
- `HERMES.md` / `AGENTS.md` / `CLAUDE.md` auto-injection (project rules)
- `~/.hermes/skills/` skill discovery (Hermes's native skill system)
- `SOUL.md` identity injection
- Memory prefetch

The executor also does **no skill setup** — `~/.hermes/skills/` is never populated.

The briefing it passes contains only: task YAML + the `## T<n>` section from `tasks.md`
+ `technical-design.md`. The scope instruction: "make code changes and save files — no
git, no PR, no result.json". No workflow guidance, no skill context, no coding
standards.

**Net effect:** Hermes runs as a generic code editor with no understanding of this
workspace's conventions, git protocol, MCP tools, or engineering standards. The quality
gap between Claude and Hermes is almost entirely attributable to this missing context —
not to an inherent capability difference.

### Hermes's native context system (from docs)

Hermes has a skill and context system almost structurally identical to Claude's:

| Concept | Claude | Hermes |
|---|---|---|
| Project rules file | `CLAUDE.md` (auto-injected) | `HERMES.md` or `AGENTS.md` (auto-injected unless `--ignore-rules`) |
| Global skills dir | `~/.claude/skills/` | `~/.hermes/skills/` |
| Skill file format | `SKILL.md` with YAML frontmatter | `SKILL.md` with YAML frontmatter (different frontmatter keys) |
| Skill invocation | `/start-implementation <args>` | `/start-implementation <args>` (same slash-command pattern) |
| MCP tool names | `mcp__<server>__<tool>` | Different invocation via `mcp_tool.py` abstraction |

Hermes's skill frontmatter schema:
```yaml
name: Skill Name
description: What the skill does
metadata:
  hermes:
    config: [list of config keys]      # optional
    platforms: [platform hints]        # optional
    requires: [required tools]         # optional
```

Context loading order (auto-injection, highest priority first):
1. `HERMES.md` or `HERMES.md` (walks to git root)
2. `AGENTS.md` / `agents.md` (current dir)
3. `CLAUDE.md` (current dir — Hermes reads this too)
4. `.cursorrules`

All files are threat-scanned and truncated to 20,000 chars before injection.

---

## 2. Problem Framing

**What specifically needs to change:**

Three things are broken in the current Hermes executor, in order of impact:

1. **`--ignore-rules` disables all native context loading.** Hermes has a context system
   designed to work exactly like Claude's — it just needs to be engaged. The flag
   blocks it unconditionally.

2. **`~/.hermes/skills/` is never populated.** Even if `--ignore-rules` were removed,
   Hermes would find no skills because the executor never stages them. The Claude
   executor has an explicit `setupGlobalSkills()` step; Hermes has no equivalent.

3. **The briefing contains no workflow guidance or coding standards.** Without CLAUDE.md
   and skills, all guidance must come from the briefing — but the current briefing only
   passes raw task content.

**What must remain stable:**

- The orchestrator ABI contract is unchanged — this feature is entirely inside the
  executor and the workflow repo.
- The wrapper's post-execution protocol (commit, push, open PR, write `result.json`)
  is unchanged — Hermes's scope remains "make code changes only".
- The `CLAUDE.md` and `workflow_skills/` / `technical_skills/` directories for Claude
  are unchanged — Claude-specific skills remain in place. This feature adds a Hermes
  layer alongside.
- The Hermes `--ignore-rules` flag removal is only safe once skill files and `HERMES.md`
  are in place. Both must ship in the same PR.

**Fixed assumptions:**

- Hermes reads `HERMES.md` from `cwd` (the task repo path) at startup — the executor
  must write this file before spawning Hermes.
- Hermes discovers `SKILL.md` files from `~/.hermes/skills/` automatically once the
  flag is removed.
- Hermes skills use slash commands identically to Claude (`/skill-name <args>`).
- The Hermes wrapper already owns git/PR/result.json — skills for Hermes must NOT
  include those steps (they are Claude-only concerns in the workflow_skills context).

---

## 3. Options Considered

### Option A — Inline all skill content into the briefing

Expand `briefing.ts` to read skill files and concatenate their content directly into
the briefing string. No Hermes skill setup, no HERMES.md — everything is in the
`--query` text.

- Pros: Simple; guaranteed delivery; no dependency on Hermes skill loading.
- Cons: Briefing becomes very large (task content + all relevant skill content > 20k
  tokens); no caching — every run pays the full cost; skill invocation changes from
  "run /skill-name" to "follow these inline instructions". Harder to maintain (skills
  would need to be kept in two places).
- Rejected: Context size and maintenance cost are too high.

### Option B — Write HERMES.md only (no skills)

Write a `HERMES.md` file to the task repo before spawning. Remove `--ignore-rules`.
Keep technical and workflow skills out of `~/.hermes/skills/`.

- Pros: Simple; `HERMES.md` carries the workflow rules; small, targeted change to the
  executor.
- Cons: Hermes still has no access to technical skills (backend-engineer, etc.) or
  workflow guidance beyond what fits in `HERMES.md`. Slash commands like
  `/start-implementation` would still fail because the skill content is absent.
- Rejected: Solves only the workflow rules gap, not the skill content gap.

### Option C — Full Hermes skill port (chosen)

Create `workflow/hermes_skills/` containing Hermes-adapted skill files. Add a
`workflow/templates/hermes/HERMES.md` (adapted from CLAUDE.md). In the executor:
add a new Phase 3.5 that sets up `~/.hermes/skills/` and writes `HERMES.md` to the
task repo. Remove `--ignore-rules`. Update the briefing to tell Hermes which skills
are available and how to invoke them.

- Pros: Uses Hermes's native context system as designed. Slash command invocation
  works identically. Skill content is maintained in one place per skill (the Hermes
  variant). Scalable — new skills are added to `hermes_skills/`, not inlined into
  the briefing. Matches the Claude executor's architecture symmetrically.
- Cons: Requires maintaining two skill directories (one per executor type). Skill
  content must be kept in sync when workflow rules change.
- Chosen.

### Option D — HERMES.md auto-loads CLAUDE.md content (piggyback)

Since Hermes auto-loads `CLAUDE.md` from `cwd`, write the workspace CLAUDE.md to
the task repo path and remove `--ignore-rules`. No new skill files needed.

- Pros: Zero-file approach for workflow rules — just enable what's already there.
- Cons: CLAUDE.md contains Claude-specific instructions (slash commands, MCP tool
  names like `mcp__gitnexus__query`) that Hermes cannot execute. Feeding raw CLAUDE.md
  to Hermes may confuse it with references to tools it does not have. Technical skills
  still not available. This is a partial fix that introduces new confusion.
- Rejected: Wrong content for Hermes; technical skills still absent.

---

## 4. Chosen Design

### 4.1 Project structure — what changes

```
workflow/
├── technical_skills/          # unchanged — Claude-flavoured technical skills
├── workflow_skills/           # unchanged — Claude-flavoured workflow skills
└── hermes_skills/             # NEW — Hermes-adapted skills
    ├── start-implementation/
    │   └── SKILL.md
    ├── backend-engineer/
    │   └── SKILL.md
    ├── typescript-best-practices/
    │   └── SKILL.md
    ├── go-best-practices/
    │   └── SKILL.md
    ├── python-best-practices/
    │   └── SKILL.md
    ├── gitnexus-mcp/
    │   └── SKILL.md
    ├── rag-context/
    │   └── SKILL.md
    └── review-pr/
        └── SKILL.md

workflow/
└── templates/
    └── hermes/
        └── HERMES.md          # NEW — Hermes equivalent of CLAUDE.md

runtime/executors/hermes/src/
├── index.ts                   # CHANGED — new Phase 3.5, drop --ignore-rules
└── briefing.ts                # CHANGED — load task-relevant Hermes skill content
```

No changes to the orchestrator, Claude executor, or ABI.

### 4.2 How Hermes will load and set up skills (vs Claude)

**Claude executor flow:**
```
Phase 1: clone mgmt repo
Phase 2: clone impl repo
Phase 3: write ~/.claude/settings.json
         copy CLAUDE.md → ~/.claude/CLAUDE.md   (auto-injected by CLI)
         copy workflow_skills/ + technical_skills/ → ~/.claude/skills/
Phase 4: build briefing → "Run /start-implementation <taskId>"
Phase 5: spawn claude -p <briefing>
         └─ CLI reads ~/.claude/CLAUDE.md → system prompt
         └─ CLI reads ~/.claude/skills/   → slash commands available
         └─ /start-implementation runs: read spec → code → test → PR → result.json
```

**Hermes executor flow (after this feature):**
```
Phase 1: clone mgmt repo
Phase 2: clone impl repo
Phase 3: write HERMES_HOME/config.yaml
Phase 3.5: NEW
         read workflow/hermes_skills/ from WORKFLOW_LOCAL_PATH
         copy hermes_skills/ → ~/.hermes/skills/   (Hermes discovers these)
         write HERMES.md → taskRepoPath/HERMES.md  (Hermes auto-loads from cwd)
Phase 4: build briefing (expanded)
         → task YAML + tasks section + technical design
         → "Available skills: /start-implementation — ..." (skill index)
         → load task-relevant technical skill content inline (fallback for skills
           not yet ported to hermes_skills/)
Phase 5: spawn hermes chat --query <briefing> --quiet
         (--ignore-rules REMOVED)
         └─ Hermes reads HERMES.md from cwd → workflow rules in system prompt
         └─ Hermes discovers ~/.hermes/skills/ → slash commands available
         └─ /start-implementation runs: read spec → code → test
         └─ (git, PR, result.json handled by wrapper)
Phase 6: wrapper: commit + push + open PR + write result.json
```

**The key structural difference:** Claude's skill for `start-implementation` includes
git, PR creation, and result.json writing. The Hermes version of `start-implementation`
must explicitly **stop** before those steps — the wrapper owns them. The briefing and
the HERMES.md must both make this boundary clear.

### 4.3 Skill classification — what needs adapting

Classification criteria:
- `portable` — content works as-is for Hermes; no Claude-specific syntax
- `adapt` — minor changes (MCP tool reference syntax, tool name mentions)
- `hermes-variant` — needs a new Hermes-specific version (different flow, different scope)
- `not-needed` — skill is for human CLI use or wrapper handles it

**Technical skills:**

| Skill | Classification | Reason |
|---|---|---|
| `backend-engineer` | portable | Pure coding standards, no Claude syntax |
| `typescript-best-practices` | portable | Pure coding standards |
| `go-best-practices` | portable | Pure coding standards |
| `python-best-practices` | portable | Pure coding standards |
| `python-data` | portable | Pure coding standards |
| `nextjs-best-practices` | portable | Pure coding standards |
| `nestjs-best-practices` | portable | Pure coding standards |
| `heroui-react` | portable | Pure UI guidance |
| `frontend-engineer` | portable | Pure engineering guidance |
| `data-engineer` | portable | Pure pipeline guidance |
| `directus-vue-engineer` | portable | Pure engineering guidance |
| `react-native-mobile-engineer` | portable | Pure mobile guidance |
| `airflow-3` | portable | Pure DAG standards |
| `pipeline-parity-qa` | adapt | Minor: references Claude tool names in one section |
| `figma-mcp` | hermes-variant | MCP invocation syntax differs; tool availability differs |
| `gitnexus-mcp` | hermes-variant | MCP tool names differ (`mcp__gitnexus__query` → different) |
| `rag-enforce` | hermes-variant | MCP tool name differs; enforcement mechanism differs |
| `review-pr` | hermes-variant | Result.json format, GitHub review API calls differ in Hermes context |
| `respond-to-review` | hermes-variant | Same as review-pr |
| `browser-qa-frontend` | adapt | Minor: references Claude browser tools |

**Workflow skills:**

| Skill | Classification | Reason |
|---|---|---|
| `start-implementation` | hermes-variant | Must stop before git/PR/result.json (wrapper owns those) |
| `rag-context` | hermes-variant | MCP invocation syntax differs |
| `pr-create` | not-needed | Wrapper handles PR creation in Phase 6 |
| `resolve-project-env` | not-needed | Wrapper already resolves env; not an interactive skill |
| `approve-feature`, `reject-feature`, etc. | not-needed | Human-interactive CLI skills only |

**Priority order for implementation** (by leverage per task):
1. `start-implementation` — used on every impl task
2. `review-pr` — used on every review task
3. `gitnexus-mcp` — highest-impact code-quality lookup
4. `rag-context` — RAG pre-flight
5. `typescript-best-practices`, `go-best-practices`, `python-best-practices` — most-used tech skills
6. `backend-engineer`, `frontend-engineer` — role guidance
7. Remaining portable skills — copy as-is

### 4.4 Adaptation approach for each skill category

#### Portable skills — copy strategy
Copy the SKILL.md from `technical_skills/<skill>/SKILL.md` into
`hermes_skills/<skill>/SKILL.md`. Update the frontmatter to Hermes format:

```yaml
# Before (Claude):
---
name: backend-engineer
description: Backend engineering role guidance...
---

# After (Hermes):
---
name: backend-engineer
description: Backend engineering role guidance...
metadata:
  hermes:
    requires: [terminal, file_tools]
---
```

No content changes needed — the coding standards, rules, and patterns are
executor-agnostic.

#### Hermes-variant: `start-implementation`
The Claude version tells Claude to "run `/start-implementation <taskId>`" — the skill
then handles reading spec, implementing, testing, opening PR, and writing result.json.

The Hermes variant must:
1. Tell Hermes to read the spec files (tasks.md section, technical-design.md)
2. Implement the required changes with incremental commits (but no git push — the wrapper does that)
3. Run the test suite
4. **Stop** — do not open a PR, do not write result.json, do not run git push

```markdown
# Hermes SKILL.md for start-implementation

You are implementing a task in an autonomous executor. The wrapper that spawned you
handles git push, PR creation, and result.json. Your job is to make the required
code changes and save them.

## Step 1 — Read the spec

1. Read the task YAML (provided in the briefing)
2. Read the ## T<n> section from tasks.md (provided in the briefing)
3. Read technical-design.md (provided in the briefing)

## Step 2 — Implement

Make the required changes in the working directory. Use the file tools to read and
write files. Use the terminal tool to run commands.

Commit incrementally as logical units:
  feat(<featureId>/<taskId>): <what you did>

## Step 3 — Test

Run the project's test suite. Check README or package.json / go.mod / Makefile for
the test command. All tests must pass before you declare the work complete.

## Step 4 — Done

When tests pass and all subtask checklist items are complete, stop. Do not run
git push, do not create a PR, do not write any result file — the wrapper handles
those steps automatically after you exit.
```

#### Hermes-variant: `gitnexus-mcp`
The Claude version uses `mcp__gitnexus__query` syntax. Hermes uses the MCP tool via
its `mcp_tool.py` abstraction with a different invocation shape. The Hermes variant
documents the correct MCP call syntax for the Hermes tool registry, and removes
references to `mcp__gitnexus__*` prefixed names.

The Hermes variant also removes the "GitNexus lookup priority rule" phrasing from
CLAUDE.md (which says "if `mcp__gitnexus__*` tools appear in your tool list") and
replaces it with Hermes-appropriate language ("if the `gitnexus` MCP server is
configured in your HERMES_HOME/config.yaml").

#### Hermes-variant: `rag-context`
Same pattern as gitnexus-mcp — remove `mcp__rag-server__rag_query` syntax, replace
with Hermes MCP invocation form.

#### Hermes-variant: `review-pr`
The Claude version invokes GitHub review API via curl (in the skill). The Hermes
wrapper should own this — so the Hermes `review-pr` skill should:
1. Read the PR diff (provided in briefing)
2. Evaluate against task spec and tech design
3. Output structured commentary as text
4. **Stop** — the wrapper posts the GitHub review API call and writes result.json

This mirrors the same scope boundary as `start-implementation`.

#### HERMES.md — the workflow rules file
The HERMES.md template carries the subset of CLAUDE.md rules that are relevant to
Hermes's scope (code changes only). It explicitly excludes:
- Task lifecycle / status transition rules (orchestrator handles these)
- Git protocol (wrapper handles commits/push)
- PR creation rules (wrapper handles these)
- Slash command invocation rules (replaced with Hermes equivalents)

It includes:
- Code quality rules (test-before-PR equivalent: "test before declaring done")
- Coding conventions (from relevant technical skills)
- Checkpoint discipline (commit incrementally; do not batch into one commit)
- MCP lookup rules (RAG-first, GitNexus-first — adapted for Hermes MCP syntax)

### 4.5 Executor changes

**`runtime/executors/hermes/src/index.ts`** — new Phase 3.5:

```typescript
// Phase 3.5: Hermes skill setup
const workflowLocalPath = process.env.WORKFLOW_LOCAL_PATH ?? "";
if (workflowLocalPath) {
  const hermesSkillsDir = join(workflowLocalPath, "hermes_skills");
  const hermesHome = /* already resolved */;
  const targetSkillsDir = join(hermesHome, "skills");
  if (existsSync(hermesSkillsDir)) {
    copyDirRecursive(hermesSkillsDir, targetSkillsDir);
    emit({ type: "phase_done", phase: "3.5a", target: targetSkillsDir });
  }
  // Write HERMES.md to task repo cwd so Hermes auto-loads it
  const hermesMdSrc = join(workflowLocalPath, "templates", "hermes", "HERMES.md");
  if (existsSync(hermesMdSrc)) {
    copyFileSync(hermesMdSrc, join(implDir, "HERMES.md"));
    emit({ type: "phase_done", phase: "3.5b", dest: join(implDir, "HERMES.md") });
  }
}
```

**Drop `--ignore-rules` from the spawn args:**

```typescript
// Before:
["chat", "--query", briefing, "--quiet", "--ignore-rules"]

// After:
["chat", "--query", briefing, "--quiet"]
```

**`runtime/executors/hermes/src/briefing.ts`** — updated `buildBriefing()`:

```typescript
// Add a skills index section to the briefing so Hermes knows what's available
const skillsSection = buildAvailableSkillsIndex(hermesSkillsDir);
// Add task-relevant technical skill content inline (for any skill not yet in hermes_skills/)
const technicalSkillContent = loadTaskTechnicalSkills(mgmtDir, featureId, taskId, hermesSkillsDir);
```

The briefing gains two new sections after the task context:
- `## Available skills` — a short index of `/skill-name — description` for each skill
  in `~/.hermes/skills/`
- `## Technical guidance` — inlined content of technical skills declared in tasks.md
  that are not yet ported to `hermes_skills/` (fallback for portables)

### 4.6 Env var additions

No new ABI env vars. One new `extraEnv` entry:
- `WORKFLOW_LOCAL_PATH` — already passed by the Claude executor (line 336 of Claude's
  `index.ts`); just needs to be added to the Hermes executor's documented `extraEnv`
  list. The orchestrator operator sets this alongside existing Hermes-specific vars.

---

## 5. Dependency Analysis

| Dependency | Status | Resolution |
|---|---|---|
| `adding-hermes-executor` (base executor) | done | Foundation in place |
| `executor-self-briefing` (executor owns briefing) | done | Briefing builder already in executor |
| `executor-capability` (impl + review) | done | Review path already wired |
| Hermes CLI installed in executor env | assumed present | No change required |
| `WORKFLOW_LOCAL_PATH` in executor env | partially present (Claude only) | Operator must add to Hermes `extraEnv` |
| Hermes MCP invocation syntax (exact) | unresolved | T1 (audit) must pin the exact form before T5 (MCP skill variants) can be written |

**Unresolved:** The exact Hermes MCP tool invocation syntax for `gitnexus` and `rag`
MCP servers is not fully confirmed from docs. T1 (audit) must run a probe to confirm
the tool call shape before T5 writes the MCP skill variants.

---

## 6. Parallelization / Blocking Analysis

```
T1: Skill gap audit — classify all skills, write audit.md, probe Hermes MCP syntax
  └── Can begin now — no blockers
  │
T2: HERMES.md template + hermes_skills/ scaffold (directory + placeholder files)
  └── Can begin now — no blockers (structure is independent of audit results)
  │
  T3: Hermes-variant core workflow skills (start-implementation, review-pr)
      └── BLOCKED on T1 (audit must confirm tool name references and scope boundary)
      └── BLOCKED on T2 (hermes_skills/ directory must exist)
      T3 and T4 run in parallel
  │
  T4: Portable technical skills — copy + frontmatter update
      └── BLOCKED on T2 (hermes_skills/ directory must exist)
      T4 can begin as soon as T2 is done (does not need T1 — portables need no content review)
  │
  T5: Hermes-variant MCP skills (gitnexus-mcp, rag-context)
      └── BLOCKED on T1 (exact MCP invocation syntax must be confirmed)
      └── BLOCKED on T2 (hermes_skills/ directory must exist)
      T5 runs after T1 + T2; may run in parallel with T3 and T4
  │
  T6: Executor changes (Phase 3.5, drop --ignore-rules, updated briefing.ts)
      └── BLOCKED on T3 (start-implementation skill must exist before executor references it)
      └── BLOCKED on T4 (skills dir must be populated)
      └── BLOCKED on T5 (MCP skill variants must exist)
      T6 is the integration step — all skill work (T3/T4/T5) must land first
  │
  T7: Validation — real impl task + real review task, before/after comparison
      └── BLOCKED on T6 (executor changes must be deployed)
```

T2 and T1 run in parallel.
T3, T4, and T5 run in parallel (all blocked on T2; T3+T5 also blocked on T1).
T6 is blocked on T3 + T4 + T5.
T7 is blocked on T6.

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `workflow` | Add `hermes_skills/` directory tree; add `templates/hermes/HERMES.md`; minor content updates to ported skills | New skill directory for Hermes; HERMES.md template |
| `workflow` | `runtime/executors/hermes/src/index.ts` — Phase 3.5 added; `--ignore-rules` removed | Executor skill setup and Hermes context loading |
| `workflow` | `runtime/executors/hermes/src/briefing.ts` — skills index + technical skill inline sections | Briefing expansion |

No changes to: orchestrator, Claude executor, ABI types, management repo structure,
or any implementation repos.

---

## 8. Validation and Release Impact

### Testing expectations

- Unit tests for Phase 3.5 in `runtime/executors/hermes/src/index.test.ts`:
  - `hermes_skills/` copied to `~/.hermes/skills/` when `WORKFLOW_LOCAL_PATH` is set
  - `HERMES.md` written to task repo
  - `--ignore-rules` absent from spawn args

- Functional test: run a real `kind=impl` task through the adapted Hermes executor on
  a simple target task (e.g. a docs update or small backend change). Confirm:
  - Hermes loads skill context (check Hermes session log for skill invocation)
  - Code changes are committed and pushed by the wrapper
  - PR is opened and `result.json` written with `terminal_status: "in_review"`

- Functional test: run a real `kind=review` task. Confirm:
  - Hermes loads `review-pr` skill
  - Output contains structured review commentary
  - GitHub review API call succeeds (APPROVE or REQUEST_CHANGES)
  - `result.json` written correctly

### Backward compatibility

- The Claude executor is entirely unchanged — no regression risk.
- The `--ignore-rules` removal only affects Hermes spawns. Hermes behaviour with
  context files enabled is well-defined; HERMES.md and skills will be in place before
  the flag is removed (Phase 3.5 runs before Phase 5).
- `WORKFLOW_LOCAL_PATH` is optional: if absent, Phase 3.5 is a no-op and the executor
  falls back to the current (limited) behaviour. No hard failure on missing path.

### Rollout

No orchestrator config changes required. Operators who run Hermes tasks need to set
`WORKFLOW_LOCAL_PATH` in `extraEnv` for the Hermes executor profile if not already
set. This is a one-line change to the orchestrator config file — not a code change.

The feature can be toggled off by reverting to `--ignore-rules` without touching skill
files. Skill files are additive and cause no harm when present.
