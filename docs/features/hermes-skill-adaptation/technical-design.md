# Technical Design

## Feature
- Feature ID: `hermes-skill-adaptation`
- Title: Hermes Skill Adaptation — Per-executor content layout, `AGENT_RUNTIME` rename, Hermes setup phase

---

## 1. Current State

### Conceptual model — setup vs runtime

The executor wrapper does NOT read skill or rules content. Its job is a thin
**setup phase**:

```
SOURCE                            STAGING                    READ BY
(in workflow repo)        →       (in executor home)    →    (agent CLI itself)
```

The agent CLI (`claude` or `hermes`) reads from its own native locations
(`~/.claude/…` or `~/.hermes/…` + cwd). The executor wrapper just copies files
into those native locations before spawning the CLI. After that point, the
wrapper has no knowledge of the content it staged.

This is important: **the executor is path-aware, not content-aware**. Adding
support for a new executor is "copy from path A to path B", not "understand
skill content".

### Claude executor — how setup works today

Files used during the Claude setup phase, today, all at the workflow repo root:

```
workflow/
├── CLAUDE.shared.md         # workspace rules (shared template)
├── workflow_skills/         # workflow skills (slash commands for Claude)
│   ├── start-implementation/SKILL.md
│   ├── pr-create/SKILL.md
│   └── …
├── technical_skills/        # technical skills (slash commands for Claude)
│   ├── backend-engineer/SKILL.md
│   ├── typescript-best-practices/SKILL.md
│   └── …
└── templates/
    └── claude-settings.json
```

`runtime/executors/claude/src/index.ts` runs three setup steps before spawning:

1. `copyWorkspaceClaude(workspaceRoot)` — copies `<mgmtRepo>/CLAUDE.md`
   (which was generated from `workflow/CLAUDE.shared.md` via
   `sync-workspace-rules`) → `~/.claude/CLAUDE.md`. The Claude CLI auto-injects
   this as system prompt.
2. `setupGlobalSkills(workspaceRoot, workflowLocalPath)` — copies all
   directories under `workflow/technical_skills/` and `workflow/workflow_skills/`
   → `~/.claude/skills/`. The Claude CLI discovers these as slash commands.
3. `setupGlobalSettings(workflowLocalPath)` — copies
   `workflow/templates/claude-settings.json` → `~/.claude/settings.json`.

The executor also sets `CLAUDE_AGENT_RUNTIME=1` on the spawned Claude process.
Skills (`start-implementation`, `pr-create`) check this env var to switch
between interactive and headless behaviour.

### Hermes executor — current state (broken)

`runtime/executors/hermes/src/index.ts` has phases 1–6 (clone mgmt repo, clone
impl repo, write `HERMES_HOME/config.yaml`, build briefing, spawn hermes chat,
post-execution commit/push/PR/result.json). The spawn line is:

```
hermes chat --query <briefing> --quiet --ignore-rules
```

`--ignore-rules` disables Hermes's native context system (HERMES.md, SOUL.md,
AGENTS.md, skill discovery, memory). There is no Hermes setup phase. The
briefing is the only content Hermes receives, and it carries just task content
— no workflow rules, no coding standards, no skill index.

### The architectural mismatch

The current workflow repo layout was authored when Claude was the only
executor. It collapses two things that should be separable:

- **Per-executor staging content** (CLAUDE.md, skills, settings) — Claude-specific
- **Universal content** (templates, schemas, scripts) — runtime-agnostic

There is no place to put Hermes-equivalent staging content (SOUL.md,
HERMES.md, Hermes-flavoured skill text) without colliding with Claude's
content. Adding `workflow/hermes/SOUL.md` alongside files like
`workflow/workflow_skills/` creates an asymmetric, confusing layout that
hides which content belongs to which executor.

The `CLAUDE_AGENT_RUNTIME=1` env var has the same problem: it was named when
"agent runtime" implied Claude. Now that there are two executors, the name
implies an executor-specific check, but every skill that reads it is asking
the executor-agnostic question *"am I headless?"*.

---

## 2. Problem Framing

**What specifically needs to change:**

1. **Workflow repo layout** — promote per-executor content to a sibling
   directory pair. `workflow/claude/` for Claude's staging content,
   `workflow/hermes/` for Hermes's staging content. Each is owned by its
   executor's setup phase and never touched by the other.

2. **`CLAUDE_AGENT_RUNTIME=1` → `AGENT_RUNTIME=1`** — rename the env var
   across the Claude executor, the Hermes executor (new), and every skill
   that reads it. The question every reader is actually asking ("am I in
   headless agent mode?") is executor-agnostic; the name should be too.
   The skills should never need to distinguish "which executor" — only
   "interactive vs headless".

3. **Hermes setup phase** — add a setup phase to the Hermes executor that
   mirrors the Claude executor's three steps:
   - Copy `workflow/hermes/SOUL.md` → `~/.hermes/SOUL.md`
   - Copy `workflow/hermes/workflow_skills/` + `workflow/hermes/technical_skills/`
     → `~/.hermes/skills/`
   - Copy `workflow/hermes/HERMES.shared.md` → `<implDir>/HERMES.md`
     (with `.git/info/exclude` protection so it does not pollute PRs)
   And drop `--ignore-rules` from the spawn line so Hermes actually loads
   the staged content.

4. **Hermes-flavoured staging content** — populate `workflow/hermes/` with
   skill files written in a form Hermes consumes well. These are **separate
   files** from Claude's, not the same files with detection blocks. The
   wrapper does not edit content; the difference between executors is the
   difference between two parallel directory trees, not branches inside a
   shared file.

**What must remain stable:**

- The orchestrator ABI is unchanged.
- The Claude executor's behaviour for existing tasks is unchanged (the
  path move + env var rename produce the same effective system, just with
  new names).
- The wrapper's post-execution protocol (commit, push, open PR, write
  `result.json`) is unchanged for both executors.

**Fixed assumptions:**

- The Hermes and Claude executors never share an in-process state and
  must not include conditional code of the shape
  `if (AGENT_RUNTIME && executor === "hermes") …`. The shape "is this
  agent runtime?" is the only allowed runtime check; the shape "which
  agent runtime?" is forbidden. Per-executor differences live entirely in
  per-executor *content* (`workflow/claude/` vs `workflow/hermes/`),
  never in shared *code*.
- The wrapper code per executor (`runtime/executors/claude/`,
  `runtime/executors/hermes/`) is independently maintained. The Hermes
  wrapper does not import from the Claude wrapper.
- `HERMES.md` and `SOUL.md` are filenames Hermes auto-loads from cwd and
  `~/.hermes/` respectively, per the Hermes docs.

---

## 3. Options Considered

### Option A — Keep current layout; add Hermes files at workflow root

Add `workflow/SOUL.md`, `workflow/HERMES.shared.md`, and Hermes skill
directories alongside the existing `workflow_skills/` and `technical_skills/`.

- Pros: minimal file movement.
- Cons: asymmetric and confusing. The reader has to know which files are
  Claude's and which are Hermes's by convention. `workflow_skills/` becomes
  implicitly "Claude's workflow skills" — a load-bearing convention with no
  marker. New executors would compound the confusion.
- Rejected.

### Option B — Shared skills with `CLAUDE_AGENT_RUNTIME` / `HERMES_AGENT_RUNTIME` detection blocks

Keep one set of skill files at the workflow root. Inside each SKILL.md,
add detection blocks for each executor that branch on env var.

- Pros: single source of truth for skill content.
- Cons: violates the "no cross-executor coupling" rule — every skill file
  now references both executors. Skill content tuned for Claude's
  instruction-following may underperform for Hermes (and vice versa).
  Detection blocks pile up linearly with each new executor. Most importantly,
  the user has rejected this — skill *content* should be tuned per executor,
  not branched inside one file.
- Rejected.

### Option C — Per-executor staging directories (chosen)

Reorganise the workflow repo into:

```
workflow/
├── claude/                       # (moved from current root)
│   ├── CLAUDE.shared.md
│   ├── workflow_skills/
│   └── technical_skills/
├── hermes/                       # (new)
│   ├── SOUL.md
│   ├── HERMES.shared.md
│   ├── workflow_skills/
│   └── technical_skills/
├── runtime/                      # unchanged
├── templates/                    # unchanged (executor-agnostic templates only)
└── …
```

Also rename `CLAUDE_AGENT_RUNTIME=1` → `AGENT_RUNTIME=1` everywhere.

- Pros: symmetric, scalable to a third executor. Each executor's wrapper
  reads from one directory and stages it into the agent's native home —
  no cross-references. Skill content is tuned per executor. The
  `AGENT_RUNTIME` env var asks the question every reader actually cares
  about.
- Cons: requires moving existing files (`workflow_skills/`,
  `technical_skills/`, `CLAUDE.shared.md`) into `claude/`. Requires updating
  the Claude executor's `setupGlobalSkills` / `copyWorkspaceClaude` paths.
  Requires updating `sync-workspace-rules` (which reads `CLAUDE.shared.md`).
  Some skill content (pure coding standards) is duplicated between
  `claude/technical_skills/` and `hermes/technical_skills/`. Duplication is
  intentional — the content can diverge over time as each model's tuning
  matures.
- **Chosen.**

### Option D — Symlinks between `claude/technical_skills/` and `hermes/technical_skills/` for portable skills

For skills that are pure coding standards (e.g. `go-best-practices`,
`typescript-best-practices`), symlink rather than duplicate.

- Pros: avoids physical duplication for skills that genuinely have one
  content version.
- Cons: symlinks have caused real bugs in this codebase before
  (`setupSkillSymlinks` was replaced in `agent-workspace-rules` precisely
  because symlinks in working trees caused git pollution). Symlinks in the
  workflow repo itself are safer (not in a working tree being staged) but
  add a subtle gotcha: editing the file from either path edits both, and
  cross-platform symlink handling on Windows is brittle. Defer this
  optimisation — start with duplication.
- Deferred (not chosen now; revisit if duplication maintenance burden
  becomes real).

---

## 4. Chosen Design

### 4.1 Repository structure

Reading guide: the tree below is rooted at **the workflow repo root**
(`/path/to/workflow/`, i.e. what `WORKFLOW_LOCAL_PATH` points at). The
top-level `workflow/` label is the repo itself, not a subdirectory inside
some other parent. Every line is annotated with its status — only the
[NEW], [MOVED], and [EDITED] lines are part of this feature's diff.

```
workflow/                                                # workflow repo root (= WORKFLOW_LOCAL_PATH)
│
├── CLAUDE.shared.md                                     [DELETED — moves into claude/]
├── workflow_skills/                                     [DELETED — moves into claude/]
├── technical_skills/                                    [DELETED — moves into claude/]
│
├── claude/                                              [NEW directory]
│   ├── CLAUDE.shared.md                                 [MOVED from workflow/CLAUDE.shared.md]
│   ├── workflow_skills/                                 [MOVED from workflow/workflow_skills/]
│   │   ├── start-implementation/SKILL.md                [MOVED — content unchanged in T2; later T6 may EDIT for AGENT_RUNTIME rename]
│   │   ├── pr-create/SKILL.md                           [MOVED + EDITED — AGENT_RUNTIME rename]
│   │   └── …                                            [MOVED]
│   └── technical_skills/                                [MOVED from workflow/technical_skills/]
│       └── …                                            [MOVED — content unchanged]
│
├── hermes/                                              [NEW directory tree]
│   ├── SOUL.md                                          [NEW — agent identity, no Claude equivalent]
│   ├── HERMES.shared.md                                 [NEW — workspace rules, Hermes-flavoured]
│   ├── workflow_skills/                                 [NEW directory]
│   │   ├── start-implementation/SKILL.md                [NEW — Hermes-flavoured; "stop before PR"]
│   │   ├── rag-context/SKILL.md                         [NEW — Hermes MCP form]
│   │   └── review-pr/SKILL.md                           [NEW — Hermes-flavoured]
│   └── technical_skills/                                [NEW directory]
│       ├── backend-engineer/SKILL.md                    [NEW — Hermes-flavoured copy]
│       ├── typescript-best-practices/SKILL.md           [NEW]
│       ├── go-best-practices/SKILL.md                   [NEW]
│       ├── python-best-practices/SKILL.md               [NEW]
│       ├── gitnexus-mcp/SKILL.md                        [NEW — Hermes MCP form]
│       └── frontend-engineer/SKILL.md                   [NEW]
│
├── product_skills/                                      [UNCHANGED — human-only skills, not executor-loaded]
├── schemas/                                             [UNCHANGED]
├── scripts/                                             [UNCHANGED]
├── docs/                                                [UNCHANGED]
├── handoffs/                                            [UNCHANGED]
│
├── templates/                                           [UNCHANGED]
│   └── claude-settings.json                             [UNCHANGED — still loaded by Claude executor]
│
└── runtime/                                             [UNCHANGED structure — only EDITS inside]
    ├── abi/                                             [UNCHANGED]
    ├── orchestrator/                                    [UNCHANGED]
    └── executors/                                       [EXISTING — established by adding-hermes-executor]
        ├── claude/                                      [EXISTING directory]
        │   └── src/
        │       └── index.ts                             [EDITED — see §4.6: source path strings + env var rename]
        │
        └── hermes/                                      [EXISTING directory]
            └── src/
                ├── index.ts                             [EDITED — see §4.5: add Phase 3.5; drop --ignore-rules; set AGENT_RUNTIME=1]
                └── briefing.ts                          [EDITED — see §4.5: skill index section + revised scope language]
```

**Important — what is NOT in this feature's diff:**

- `runtime/executors/` is **not new**. It already exists; this feature touches code inside two files but adds no new directories under `runtime/`.
- `runtime/executors/claude/` and `runtime/executors/hermes/` were created by `adding-hermes-executor` (already shipped). This feature edits files inside both; it does not change the sibling structure.
- There is **no `workflow/runtime/executors/`** as a separate or new path. The `runtime/` directory in the diagram is the existing one at the workflow repo root.

The two **content-staging subdirectories** (`workflow/claude/` and
`workflow/hermes/`) are **siblings of equal status**. Each is owned by
its executor's setup phase (the code that already lives in
`runtime/executors/<exec>/src/index.ts`) and never touched by the other.

**Per-workspace files (in each management repo, NOT in the workflow repo):**

Every workspace that uses this workflow already has a `CLAUDE.md` at its
root. After this feature, it also gets a `HERMES.md` at its root. Both
are workspace-owned, both maintained by `sync-workspace-rules`. The
workflow repo holds the *templates* (`*.shared.md`); the workspace
repos hold the *per-project files*.

```
<each management repo>/                                  # e.g. /Users/matthew/workspace/workspace/
├── CLAUDE.md                                            [EXISTING — project-local + synced shared block]
├── HERMES.md                                            [NEW — added on first sync after this feature ships]
└── …
```

The skills, SOUL.md, and `claude-settings.json` do not have a per-workspace
file — they are staged Tier 1 → Tier 3 (workflow → executor home) without
a workspace stop in between.

### 4.2 The three-tier content layout

Both executors share the same conceptual layout. Every piece of agent-facing
content has up to three tiers:

```
TIER 1 — WORKFLOW (shared template)                      lives in:  workflow repo
   │   one canonical version, all workspaces using this workflow inherit from here
   ▼
TIER 2 — WORKSPACE (per-project file)                    lives in:  management repo
   │   one per workspace; carries Tier 1 verbatim between markers
   │   plus workspace-specific content above/below the markers
   ▼
TIER 3 — EXECUTOR STAGING (agent native location)        lives in:  executor work-dir
   │   one per task spawn; written by the executor wrapper from Tier 2
   ▼
   AGENT CLI auto-loads at Tier 3 location
```

The transitions between tiers are:

- **Tier 1 → Tier 2**: performed by the `sync-workspace-rules` skill,
  run by humans/agents when workflow rules change. Preserves workspace-local
  content above the `<!-- BEGIN SHARED WORKFLOW RULES -->` marker and below
  the `<!-- END SHARED WORKFLOW RULES -->` marker.
- **Tier 2 → Tier 3**: performed by the executor wrapper at task spawn
  time. Pure file copy; no content rewriting.

#### Claude — the existing flow (unchanged structurally; paths updated)

| Content | Tier 1 (workflow) | Tier 2 (workspace) | Tier 3 (executor) | Read by |
|---|---|---|---|---|
| Workspace rules | `workflow/claude/CLAUDE.shared.md` *(moved)* | `<mgmtRoot>/CLAUDE.md` | `~/.claude/CLAUDE.md` | Claude CLI system prompt |
| Workflow skills | `workflow/claude/workflow_skills/*` *(moved)* | *(no Tier 2 — bypasses)* | `~/.claude/skills/*` | Claude CLI slash commands |
| Technical skills | `workflow/claude/technical_skills/*` *(moved)* | *(no Tier 2 — bypasses)* | `~/.claude/skills/*` | Claude CLI slash commands |
| Workspace-local skills | *(no Tier 1)* | `<mgmtRoot>/.claude/skills/*` | `~/.claude/skills/*` | Claude CLI slash commands |
| Claude settings | `workflow/templates/claude-settings.json` | *(no Tier 2)* | `~/.claude/settings.json` | Claude CLI |

Skills today skip Tier 2 — the executor copies directly from the workflow
repo. That stays as-is; we are not adding a per-workspace skill sync. (Workspaces
can still drop skills into `<mgmtRoot>/.claude/skills/` and the executor merges
them, which is the existing "workspace-local skills take precedence" path.)

#### Hermes — the symmetric flow (new)

| Content | Tier 1 (workflow) | Tier 2 (workspace) | Tier 3 (executor) | Read by |
|---|---|---|---|---|
| Workspace rules | `workflow/hermes/HERMES.shared.md` | `<mgmtRoot>/HERMES.md` | `<implDir>/HERMES.md` *(+`.git/info/exclude`)* | Hermes CLI auto-load from cwd |
| Agent identity | `workflow/hermes/SOUL.md` | *(no Tier 2 — workspace-agnostic)* | `~/.hermes/SOUL.md` | Hermes CLI identity injection |
| Workflow skills | `workflow/hermes/workflow_skills/*` | *(no Tier 2)* | `~/.hermes/skills/*` | Hermes CLI slash commands |
| Technical skills | `workflow/hermes/technical_skills/*` | *(no Tier 2)* | `~/.hermes/skills/*` | Hermes CLI slash commands |

Notes on the Hermes column:

- **HERMES.md goes through Tier 2** for the same reason CLAUDE.md does: each
  workspace must be able to add project-local context (project name, purpose,
  any Hermes-relevant project-specific rules) without forking the workflow
  template. The executor never reads `workflow/hermes/HERMES.shared.md`
  directly at task spawn time — it reads `<mgmtRoot>/HERMES.md` (which
  carries the synced Tier 1 content plus workspace additions).
- **SOUL.md skips Tier 2.** Agent identity is workspace-agnostic; the
  executor copies the workflow template straight to the agent's native
  location. (If workspace-level identity customisation is needed later,
  Tier 2 can be added without restructuring the rest.)
- **Skills skip Tier 2 in the same way Claude's do today** — the executor
  copies directly from the workflow repo. Workspace-local Hermes skill
  overrides (analogous to `.claude/skills/`) are out of scope for this
  feature.

Both wrappers behave identically structurally: a setup phase that copies a
small set of files from Tier 1 / Tier 2 sources into the agent's native
locations, then the spawn. The wrappers do not read each other's directories
and have no shared imports for staging logic.

### 4.2a Compatibility with `claude-md-rule-index`

The `claude-md-rule-index` feature (currently in design — not yet shipped)
will slim `CLAUDE.shared.md` to ~50 lines and move detailed rules into
`workflow/rules/<topic>.md` fragment files, lazy-loaded on demand by agents.

This feature is forward-compatible without coordination:

- **HERMES.shared.md mirrors CLAUDE.shared.md's structure today** — same
  marker convention, same Tier 1/Tier 2 split, same `sync-workspace-rules`
  pathway. When `claude-md-rule-index` slims one, the same slimming pattern
  applies to the other.
- **Rule fragments**: when `claude-md-rule-index` ships, *its* design will
  decide whether the rule fragments live at `workflow/rules/` (shared between
  executors) or `workflow/claude/rules/` + `workflow/hermes/rules/`
  (per-executor). Either choice is reachable from the layout this feature
  ships. We do not preempt that decision here.
- **No new artifact lock-in.** This feature does not produce any artifact
  that `claude-md-rule-index` would have to undo. HERMES.shared.md is
  initially "full-fat" (mirroring today's CLAUDE.shared.md) and is slimmed
  later by the same feature that slims CLAUDE.shared.md.

Ship order is therefore independent — neither feature blocks the other.

### 4.3 `AGENT_RUNTIME=1` rename

The Claude executor currently exports:

```typescript
process.env.CLAUDE_AGENT_RUNTIME = "1";
```

Rename to:

```typescript
process.env.AGENT_RUNTIME = "1";
```

The Hermes executor (new) also sets `AGENT_RUNTIME=1`. Skills that
previously checked `$CLAUDE_AGENT_RUNTIME` are updated to check
`$AGENT_RUNTIME`.

**Skills must NOT branch on which executor is running.** A check like
`if [ "$AGENT_RUNTIME" = "1" ] && [ "$EXECUTOR_TYPE" = "hermes" ]` is
forbidden — the difference between executors is the difference between
the Hermes and Claude versions of the *skill file itself*, not a branch
inside a shared file. The skill in `workflow/hermes/workflow_skills/`
already knows it is the Hermes version; the skill in
`workflow/claude/workflow_skills/` already knows it is the Claude
version. Each tunes its content accordingly.

The check `if $AGENT_RUNTIME = 1` (interactive vs headless) is the only
runtime check skills are allowed to make.

Files that mention `CLAUDE_AGENT_RUNTIME` today and must be updated:

- `runtime/executors/claude/src/index.ts` — env var set
- `workflow/workflow_skills/start-implementation/SKILL.md` — env var check
- `workflow/workflow_skills/pr-create/SKILL.md` — env var check
- `workflow/CLAUDE.shared.md` — "Agent-runtime detection rule" section
- Any other skill files matching `grep -r CLAUDE_AGENT_RUNTIME workflow/`

These will be located and renamed in one pass during the migration task.

### 4.4 What goes in `workflow/hermes/`

#### `workflow/hermes/SOUL.md` — Hermes agent identity

Hermes-specific (Claude has no equivalent). Auto-injected by Hermes from
`~/.hermes/SOUL.md` as identity-level system prompt. Workspace-agnostic
(same identity across all workspaces this Hermes executor serves).

Content focus:
- Operating mode (headless executor, no human in the loop, no clarifying
  questions, exit cleanly)
- Boundary of responsibility (wrapper owns git push, PR creation,
  result.json; agent owns code changes + tests + local commits)
- Tooling reality:
  - Use the Hermes tool registry (file tools, terminal, etc.)
  - **MCP tools are available**: `rag` (project knowledge retrieval) and
    `gitnexus` (structural code-graph lookups) are configured in
    `HERMES_HOME/config.yaml` by the executor (see §4.5). Invoke them
    using Hermes's MCP invocation form (NOT Claude's
    `mcp__<server>__<tool>` prefix naming).
  - Use the RAG MCP **before** opening files for lookups; use the
    GitNexus MCP **before** grep for structural code questions.
    Detailed lookup-order rules live in HERMES.md (workspace rules)
    and in the per-skill `rag-context` and `gitnexus-mcp` skills.

#### `workflow/hermes/HERMES.shared.md` — Workspace rules, Hermes-flavoured

The Hermes equivalent of `workflow/claude/CLAUDE.shared.md`. The Hermes
executor copies this to `<implDir>/HERMES.md` so Hermes auto-loads it from
cwd. Truncated to 20,000 chars by Hermes — must be a focused subset, not a
full copy of CLAUDE.shared.md.

Content focus:
- Code quality rules (test-before-declaring-done, lint expectations)
- Workspace coding conventions
- Checkpoint discipline (commit incrementally — reinforces SOUL.md)
- MCP lookup rules (RAG-first, GitNexus-first — written in Hermes MCP
  invocation form)
- Repo identity reminder

Things deliberately excluded from HERMES.shared.md (because the wrapper
or orchestrator owns them):
- Task lifecycle / status transition rules
- Git push / PR open protocol
- PR title format rules
- Slash command catalogue for Claude

#### `workflow/hermes/workflow_skills/`

Per-skill SKILL.md files written for Hermes. **Different files** from
Claude's versions — content tuned to Hermes's instruction-following style
and tool registry, not detection blocks inside shared files.

Initial skill set (essentials only — additional skills can be added
incrementally):
- `start-implementation/SKILL.md` — read spec, implement, commit
  incrementally, run tests; stop before push/PR/result.json
- `rag-context/SKILL.md` — Hermes MCP form of RAG pre-flight
- `review-pr/SKILL.md` — read PR diff, evaluate against spec; stop before
  posting review (wrapper posts review and writes result.json)

Skills NOT ported because the wrapper owns the behaviour:
- `pr-create` — wrapper opens PR in Phase 6
- `respond-to-review` — handled by `kind=fix` path (deferred)

#### `workflow/hermes/technical_skills/`

Per-skill SKILL.md files for technical/coding skills. Initially focused
on the highest-leverage skills (used by the most tasks):
- `backend-engineer/SKILL.md`
- `typescript-best-practices/SKILL.md`
- `go-best-practices/SKILL.md`
- `python-best-practices/SKILL.md`
- `gitnexus-mcp/SKILL.md` — Hermes MCP invocation form
- `frontend-engineer/SKILL.md`

Additional skills (`figma-mcp`, `nextjs-best-practices`, `react-native-...`,
etc.) can be added later as needed — not blocking.

Content for the "portable" skills (coding standards) starts as a copy of
the Claude version with:
- Tool-name references updated (no `mcp__…` prefixes; Hermes MCP form)
- Any Claude-specific behaviour notes removed
- Frontmatter updated to Hermes schema (`metadata.hermes.requires:` etc.)

These are physical copies — they may drift from Claude's versions over
time and that is acceptable.

### 4.5 Hermes executor changes — edits to existing files

The Hermes executor already exists at `workflow/runtime/executors/hermes/`
(established by `adding-hermes-executor`). This section describes edits to
files inside that existing directory — no new files, no new subdirectories.

**`workflow/runtime/executors/hermes/src/index.ts`** — new Phase 3.5 between
Phase 3 (write config.yaml) and Phase 4 (build briefing):

```typescript
// Phase 3.5: Hermes context + skill staging
// Pulls Tier 1 content from the workflow repo for SOUL.md and skills.
// Pulls Tier 2 content from the management repo clone for HERMES.md
// (the per-workspace file, already synced by sync-workspace-rules).
const workflowLocalPath = process.env.WORKFLOW_LOCAL_PATH ?? "";
if (workflowLocalPath) {
  const hermesSrc = join(workflowLocalPath, "hermes");

  // 3.5a — Tier 1 → Tier 3: SOUL.md → ~/.hermes/SOUL.md
  // SOUL.md skips Tier 2 (workspace-agnostic).
  const soulSrc = join(hermesSrc, "SOUL.md");
  if (existsSync(soulSrc)) {
    copyFileSync(soulSrc, join(hermesHome, "SOUL.md"));
  }

  // 3.5b — Tier 1 → Tier 3: workflow_skills/ + technical_skills/ → ~/.hermes/skills/
  // Skills skip Tier 2 (matches Claude executor's existing pattern).
  const targetSkillsDir = join(hermesHome, "skills");
  if (existsSync(targetSkillsDir)) rmSync(targetSkillsDir, { recursive: true, force: true });
  mkdirSync(targetSkillsDir, { recursive: true });
  for (const src of [
    join(hermesSrc, "workflow_skills"),
    join(hermesSrc, "technical_skills"),
  ]) {
    if (existsSync(src)) {
      for (const entry of readdirSync(src)) {
        copyDirRecursive(join(src, entry), join(targetSkillsDir, entry));
      }
    }
  }

  // 3.5c — Tier 2 → Tier 3: <mgmtRoot>/HERMES.md → <implDir>/HERMES.md
  // Hermes auto-loads from cwd; cwd is the impl repo.
  // The workspace HERMES.md was synced from workflow/hermes/HERMES.shared.md
  // by sync-workspace-rules (Tier 1 → Tier 2 transition).
  const workspaceHermesMd = join(mgmtDir, "HERMES.md");
  if (existsSync(workspaceHermesMd)) {
    copyFileSync(workspaceHermesMd, join(implDir, "HERMES.md"));

    // 3.5d — local-only ignore so Phase 6 git add -A does not stage HERMES.md
    // .git/info/exclude is local to this clone and not committed; safe to append.
    const excludePath = join(implDir, ".git", "info", "exclude");
    if (existsSync(dirname(excludePath))) {
      appendFileSync(excludePath, "\n# Hermes auto-loaded workspace rules (local-only)\nHERMES.md\n");
    }
  } else {
    // Tier 2 file missing — workspace has not yet run sync-workspace-rules.
    // Emit a warning event but do not block; Hermes will still run with just
    // SOUL.md and skills (degraded but functional).
    emit({ type: "phase_3_5_workspace_hermes_missing", workspace_hermes_md: workspaceHermesMd });
  }

  emit({ type: "phase_done", phase: 3.5, hermes_src: hermesSrc, mgmt_src: mgmtDir });
}
```

**Path summary for Phase 3.5:**

| Step | Tier | Source path (resolved at runtime) | Destination path |
|---|---|---|---|
| 3.5a | T1 → T3 | `$WORKFLOW_LOCAL_PATH/hermes/SOUL.md` | `$HERMES_HOME/SOUL.md` |
| 3.5b | T1 → T3 | `$WORKFLOW_LOCAL_PATH/hermes/{workflow_skills,technical_skills}/*` | `$HERMES_HOME/skills/*` |
| 3.5c | T2 → T3 | `<mgmtDir>/HERMES.md` *(already cloned in Phase 1)* | `<implDir>/HERMES.md` |
| 3.5d | — | *(no read)* | append to `<implDir>/.git/info/exclude` |

The executor reads `<mgmtDir>/HERMES.md` (not the workflow template) so each
workspace's project-local Hermes context flows through to the agent. This
mirrors how the Claude executor reads `<mgmtDir>/CLAUDE.md`.

#### Why `.git/info/exclude` — design justification

The HERMES.md placement is dictated by Hermes itself, not by us. Hermes's
context loader looks for `HERMES.md` by **walking from cwd up to the
nearest git root**. The Hermes process must run with cwd = the impl repo
(otherwise file tools and terminal commands target the wrong tree), so
HERMES.md must land somewhere inside the impl repo's working tree for
Hermes to find it.

The wrapper's Phase 6 then runs `git add -A` over that same tree as part
of committing the agent's code changes. Without protection, HERMES.md
ends up in every Hermes PR.

Three alternatives were considered:

1. **Inline HERMES.md into the briefing** — content delivered via
   `--query` string instead of a file. **Rejected**: Hermes's docs are
   explicit that project-context files (HERMES.md, AGENTS.md, etc.)
   are loaded into the **system prompt** which is built once and
   restored on resume for prefix-caching efficiency. Inlining into the
   briefing puts the content in the first user message, taking it out
   of the layer Hermes explicitly designed for stable, cacheable
   context. For a 150-iteration tool-use loop, this is a meaningful
   cost difference (HERMES.md tokens potentially paid per-iteration
   instead of once per session).

2. **Write HERMES.md to `<implDir>`, then `rm` it before `git add -A`** —
   ephemeral file, lives only during Hermes's session. **Rejected**:
   couples Phase 6 to Phase 3.5 (Phase 6 has to know about HERMES.md
   as a cleanup item). Adds a TOCTOU consideration if Hermes is still
   running. Uses an unintended mechanism (rm) where git already
   provides the right one.

3. **`.git/info/exclude`** (chosen) — git's own local-only ignore
   mechanism. `info/exclude` is git's documented hook for ignore
   patterns that should NOT be committed (unlike `.gitignore`, which
   IS committed). The append is local to the executor's clone and
   never reaches origin. This is exactly the use case the file was
   designed for. Hermes uses its native auto-load (preserving the
   system-prompt caching benefit); the PR stays clean; no Phase 6
   coupling.

**Spawn changes:**

```typescript
// Drop --ignore-rules
const spawnArgs = ["chat", "--query", briefing, "--quiet"];

// Set AGENT_RUNTIME=1
const env: NodeJS.ProcessEnv = {
  ...process.env,
  HERMES_HOME: hermesHome,
  HERMES_INFERENCE_MODEL: hermesModel,
  HERMES_INFERENCE_PROVIDER: hermesProvider,
  HERMES_MAX_ITERATIONS: hermesMaxTurns,
  HERMES_YOLO_MODE: "1",
  AGENT_RUNTIME: "1",
};
```

**Briefing changes (lighter-touch than original draft):**

Now that SOUL.md and HERMES.md carry identity and workspace rules, the
briefing's job shrinks to task content + a skill index. The current
"Make the required code changes and save the files. Do not commit, …"
closing language is updated to:

> *"Make the required code changes and commit them incrementally with
> `feat(<featureId>/<taskId>): <what>` messages. Run the project's test
> suite before you stop. Do NOT run `git push`, do NOT open a pull
> request, do NOT write any result file — the wrapper handles those
> steps after you exit."*

A new `## Available skills` section lists the slash commands present in
`~/.hermes/skills/` (built by scanning the staged dir for SKILL.md
frontmatter).

**Phase 3 (config.yaml) — extend to wire GitNexus MCP:**

Today the Hermes executor's `writeHermesConfig()` writes an optional `rag`
MCP server stanza when `RAG_MCP_URL` is set. It does NOT yet support
GitNexus, but Hermes is fully capable of consuming MCP — the existing RAG
plumbing proves it. We extend the config writer to also wire `gitnexus`
when its URL is present.

```typescript
// Current (excerpt from runtime/executors/hermes/src/index.ts ~line 303):
if (config.ragMcpUrl) {
  configObj.mcp_servers = {
    rag: {
      url: config.ragMcpUrl,
      ...(config.ragMcpToken ? { headers: { Authorization: `Bearer ${config.ragMcpToken}` } } : {}),
    },
  };
}

// Extended:
if (config.ragMcpUrl || config.gitnexusMcpUrl) {
  configObj.mcp_servers = {};
  if (config.ragMcpUrl) {
    configObj.mcp_servers.rag = {
      url: config.ragMcpUrl,
      ...(config.ragMcpToken ? { headers: { Authorization: `Bearer ${config.ragMcpToken}` } } : {}),
    };
  }
  if (config.gitnexusMcpUrl) {
    configObj.mcp_servers.gitnexus = {
      url: config.gitnexusMcpUrl,
    };
  }
}
```

And in `main()`, read the new env var alongside the existing ones:

```typescript
const gitnexusMcpUrl = process.env.GITNEXUS_MCP_URL;
// …
writeHermesConfig(hermesHome, {
  provider: hermesProvider,
  model: hermesModel,
  ragMcpUrl,
  ragMcpToken,
  gitnexusMcpUrl,        // NEW
});
```

**Env var contract additions for the Hermes executor (operator-injected
via `SubProcessAdapterOpts.extraEnv`):**

| Variable | Status | Purpose |
|---|---|---|
| `RAG_MCP_URL` | already supported | Wires `rag` MCP server in config.yaml |
| `RAG_MCP_TOKEN` | already supported | Optional auth header for RAG MCP |
| `GITNEXUS_MCP_URL` | **NEW** | Wires `gitnexus` MCP server in config.yaml |
| `WORKFLOW_LOCAL_PATH` | already passed for Claude; need for Hermes | Phase 3.5 reads `workflow/hermes/` from here |
| `AGENT_RUNTIME=1` | NEW (set by executor, not operator) | Tells skills they are headless |

Operator workflow: the orchestrator config that already sets
`GITNEXUS_MCP_URL` for the Claude executor needs the same value forwarded
to the Hermes executor's `extraEnv`. One-line config change, no orchestrator
code change.

Figma MCP is not wired in this feature — the Claude executor uses it
because its `--mcp-config` flow supports stdio-spawned MCPs; the Hermes
config.yaml form requires confirming the exact stanza shape. Defer to a
follow-up if Figma-driven tasks become a real Hermes target.

### 4.6 Claude executor changes — edits to existing files

The Claude executor already exists at `workflow/runtime/executors/claude/`.
This section describes edits to files inside that existing directory — no
new files, no new subdirectories.

**`workflow/runtime/executors/claude/src/index.ts`** (current state today,
lines 270–271):

```typescript
copySkillsFrom(join(workflowLocalPath, "technical_skills"));
copySkillsFrom(join(workflowLocalPath, "workflow_skills"));
```

This becomes:

```typescript
copySkillsFrom(join(workflowLocalPath, "claude", "technical_skills"));
copySkillsFrom(join(workflowLocalPath, "claude", "workflow_skills"));
```

And the spawn env block (search for `CLAUDE_AGENT_RUNTIME` in the file):

```typescript
// Before:
CLAUDE_AGENT_RUNTIME: "1",
// After:
AGENT_RUNTIME: "1",
```

No other changes to the Claude executor — the rest of `index.ts`
(repo materialisation, briefing, recovery, etc.) stays as-is.

### 4.7 `sync-workspace-rules` skill — extend to handle HERMES.md

The skill currently lives at `workflow/workflow_skills/sync-workspace-rules/SKILL.md`
(moves to `workflow/claude/workflow_skills/sync-workspace-rules/SKILL.md` in T2).
It currently performs the **Tier 1 → Tier 2** transition for the Claude side
only: reads `workflow/CLAUDE.shared.md` (→ `workflow/claude/CLAUDE.shared.md`
after T2), updates `<projectRoot>/CLAUDE.md` between the
`<!-- BEGIN SHARED WORKFLOW RULES -->` / `<!-- END SHARED WORKFLOW RULES -->`
markers, preserving content outside the markers.

Extension: add an analogous step for HERMES.md.

**Two-pass logic in the skill body:**

```
Step A (existing) — CLAUDE.md sync:
  Read workflow/claude/CLAUDE.shared.md
  Read <projectRoot>/CLAUDE.md
  Replace content between BEGIN/END markers in <projectRoot>/CLAUDE.md
  Preserve content above the opening marker and below the closing marker.

Step B (new) — HERMES.md sync:
  Read workflow/hermes/HERMES.shared.md
  If <projectRoot>/HERMES.md does not exist:
    Create it from a template:
      # <project name> — Hermes operating rules
      <!-- BEGIN SHARED WORKFLOW RULES -->
      <content of workflow/hermes/HERMES.shared.md>
      <!-- END SHARED WORKFLOW RULES -->
  Otherwise:
    Read <projectRoot>/HERMES.md
    Replace content between BEGIN/END markers
    Preserve content above/below the markers.
```

Both steps run on every invocation of the skill. They are independent — if
`workflow/hermes/HERMES.shared.md` does not exist (workflows that have not
adopted Hermes yet), Step B becomes a no-op and emits a `hermes_shared_missing`
event without failing.

This is a small extension to one skill file. No new skill is introduced — keeps
the "one place to sync workspace rules" convention.

The first workspace owner who runs the updated skill creates the workspace's
`HERMES.md`. From then on, sync keeps it aligned with the workflow template,
the same way CLAUDE.md is kept aligned today.

**`sync-workspace-rules` skill** (`workflow/workflow_skills/sync-workspace-rules/SKILL.md`,
which itself moves to `workflow/claude/workflow_skills/sync-workspace-rules/SKILL.md`):

- Change source path for the shared rules file from
  `<workflowRoot>/CLAUDE.shared.md` to
  `<workflowRoot>/claude/CLAUDE.shared.md`.

**Workspace `CLAUDE.md`** (in each project workspace, generated by
`sync-workspace-rules`):

- "Agent-runtime detection rule" section: rename
  `CLAUDE_AGENT_RUNTIME` → `AGENT_RUNTIME`. (Workspaces using
  `sync-workspace-rules` after this PR pick this up automatically.)

### 4.7 What stays the same

- The orchestrator (`runtime/orchestrator/`) — zero changes.
- The ABI (`runtime/abi/`) — zero changes.
- The Hermes wrapper post-execution protocol (commit, push, open PR,
  write `result.json`) — unchanged.
- The Claude executor's behaviour from the agent's point of view —
  unchanged. The path move and env var rename produce the same effective
  system; nothing the Claude agent observes changes.

---

## 5. Dependency Analysis

| Dependency | Status | Resolution |
|---|---|---|
| `adding-hermes-executor` (base executor) | done | Foundation in place |
| `executor-self-briefing` (executor owns briefing) | done | Briefing builder lives in executor |
| `executor-capability` (impl + review) | done | Review path wired |
| `WORKFLOW_LOCAL_PATH` in Hermes `extraEnv` | needs operator config | Already passed for Claude; Hermes operator config must add it |
| `RAG_MCP_URL` in Hermes `extraEnv` | already supported by Hermes executor | Operator already sets this for Hermes (existing wiring in writeHermesConfig) |
| `GITNEXUS_MCP_URL` in Hermes `extraEnv` | NEW — needs operator config + executor extension (T6) | Mirror the Claude executor's existing GitNexus wiring; same env var name |
| Hermes MCP invocation syntax (how skills should call the tools) | unresolved | T1 audit confirms exact form before T4/T5 write rag-context and gitnexus-mcp skills |
| Hermes skill frontmatter (`metadata.hermes.requires`) values | unresolved | T1 audit confirms exact tool-name strings |
| `sync-workspace-rules` reads new path | resolved in T2 | Path change is part of the move task |
| `AGENT_RUNTIME` rename does not break old skills | resolved in T2 | Atomic rename across all referencing files in one PR |

**Items previously unresolved — closed during design (no longer T1 blockers):**

1. **Hermes MCP tool naming convention** — **CLOSED**. Hermes registers MCP
   tools as `mcp_<server>_<tool>` (single underscores, hyphens and dots
   sanitised to `_`). Source: Hermes `tools/mcp_tool.py` (`_refresh_tools`
   method) and `website/docs/reference/mcp-config-reference.md`.

   For our MCP servers, the exact tool names the agent must call are:

   | MCP server (config.yaml key) | Tool exposed | Hermes tool name |
   |---|---|---|
   | `rag` | `rag_query` | `mcp_rag_rag_query` |
   | `gitnexus` | `query` | `mcp_gitnexus_query` |
   | `gitnexus` | `context` | `mcp_gitnexus_context` |
   | `gitnexus` | `impact` | `mcp_gitnexus_impact` |
   | `gitnexus` | `detect_changes` | `mcp_gitnexus_detect_changes` |

   This is the exact form to use in the `rag-context` and `gitnexus-mcp`
   skills (T4 + T5). Note this is single-underscore, NOT Claude's
   `mcp__server__tool` double-underscore prefix.

2. **Skill frontmatter required-tool values** — **CLOSED**. There is no
   generic `requires:` key. Hermes uses two distinct fields:

   - `metadata.hermes.requires_toolsets: [<toolset>, ...]` — required
     toolset names
   - `metadata.hermes.requires_tools: [<tool>, ...]` — required individual
     tool names

   Valid toolset values for our skills (from `website/docs/reference/tools-reference.md`):
   `terminal`, `file`, `web`, `code_execution`, `delegation`, `session_search`,
   plus others not relevant here. For technical/coding skills like
   `backend-engineer`, `typescript-best-practices`, etc., the right
   frontmatter is:

   ```yaml
   metadata:
     hermes:
       requires_toolsets: [terminal, file]
   ```

   Per GitHub Issue #416 in the Hermes repo, invalid values are silently
   accepted (no validation); the skill simply never activates. Source:
   Hermes `agent/skill_utils.py` `extract_skill_conditions()` line 233.

3. **`.git/info/exclude` vs Hermes file read** — **CLOSED by mechanics**.
   `.git/info/exclude` is git's local-only ignore mechanism (parallel to
   `.gitignore` but never committed). It affects `git status`, `git add`,
   `git ls-files`, and other git plumbing. It does **not** touch the
   filesystem — the file at `<implDir>/HERMES.md` is fully readable by
   any non-git tool (including Hermes). No probe needed; this is a
   guaranteed property of `info/exclude`'s implementation.

**Remaining open items** (none that block design — all are operator-
config matters for T6/T7):

- Operator config to set `WORKFLOW_LOCAL_PATH` and `GITNEXUS_MCP_URL`
  in the Hermes executor's `extraEnv`. Trivial — same value the Claude
  executor already gets.

---

## 6. Parallelization / Blocking Analysis

```
T1: Audit (scope reduced — primary unknowns resolved during design; see §5)
    - Classify every existing Claude technical_skills/* skill as
      portable | adapt | hermes-variant (informs T5 content work)
    - Verify HERMES.md vs CLAUDE.md precedence by inspection — both
      files would be in cwd? we only write HERMES.md, but document the
      observed ordering for future reference
    - Produce docs/features/hermes-skill-adaptation/audit.md
  └── Can begin now — no blockers
  └── MCP naming (mcp_<server>_<tool>) and frontmatter schema
       (requires_toolsets, requires_tools) are already resolved in §5
       — T1 no longer probes these

T2: Workflow repo reorg + AGENT_RUNTIME rename (single atomic PR)
    - mv workflow/CLAUDE.shared.md      → workflow/claude/CLAUDE.shared.md
    - mv workflow/workflow_skills/      → workflow/claude/workflow_skills/
    - mv workflow/technical_skills/     → workflow/claude/technical_skills/
    - Update Claude executor index.ts: source paths + env var name
    - Update sync-workspace-rules skill: source path for CLAUDE.shared.md
    - Rename CLAUDE_AGENT_RUNTIME → AGENT_RUNTIME everywhere
    - Update CLAUDE.shared.md "Agent-runtime detection rule" text
  └── Can begin now — no blockers
  └── Must land as one PR; partial state breaks the Claude executor.

T3: workflow/hermes/SOUL.md + HERMES.shared.md authoring
  └── Can begin now — content is workspace-agnostic; covered in §4.4
  └── No code dependency on T1 or T2

T3b: Extend sync-workspace-rules to also sync HERMES.md (Tier 1 → Tier 2)
     - Add Step B to the skill body (see §4.7)
     - When workspace HERMES.md does not exist, create it from the template
     - Idempotent; degrades gracefully when HERMES.shared.md absent
  └── BLOCKED on T2 (skill source path for CLAUDE.shared.md is in T2)
  └── BLOCKED on T3 (HERMES.shared.md must exist to sync from)
  └── Lightweight task — combined with one of T2/T3 if it fits in scope

T4: workflow/hermes/workflow_skills/ — Hermes-flavoured workflow skills
    (start-implementation, rag-context, review-pr)
    Use `mcp_rag_rag_query` for RAG invocation (resolved in §5)
  └── Can begin now — MCP form known, scope boundary documented in §4.4

T5: workflow/hermes/technical_skills/ — Hermes-flavoured technical skills
    (backend-engineer, typescript-best-practices, go-best-practices,
    python-best-practices, gitnexus-mcp, frontend-engineer)
    Use `mcp_gitnexus_query`/`mcp_gitnexus_context`/`mcp_gitnexus_impact`
    in gitnexus-mcp. Use `requires_toolsets: [terminal, file]` in
    frontmatter (resolved in §5)
  └── Can begin now — MCP form and frontmatter schema known
  └── Soft-blocked on T1 only if portability classification matters for
       which Claude content to copy as the starting point

T6: Hermes executor Phase 3.5 implementation
    - index.ts: copy SOUL.md, skills (from workflow/hermes/) — Tier 1 → Tier 3
    - index.ts: copy HERMES.md (from <mgmtDir>/HERMES.md) — Tier 2 → Tier 3
    - index.ts: append HERMES.md to .git/info/exclude
    - index.ts: drop --ignore-rules; set AGENT_RUNTIME=1
    - briefing.ts: skill index + revised scope language
    - Unit tests
  └── BLOCKED on T2 (Claude executor must have already moved to
       AGENT_RUNTIME=1 — keeps both executors aligned in one direction)
  └── BLOCKED on T3 (SOUL.md + HERMES.shared.md must exist to copy)
  └── BLOCKED on T3b (workspace HERMES.md must be reachable for at
       least the validation workspace — without it, Phase 3.5c is a no-op)
  └── BLOCKED on T4, T5 (skills must exist to copy)

T7: Validation — real impl + real review task on Hermes, before/after quality comparison
  └── BLOCKED on T6
```

**Wave ordering:**
- Wave 1 (parallel): T1, T2, T3, T4, T5 (all five can start immediately
  now that the design-time unknowns are resolved)
- Wave 2: T3b (after T2 + T3)
- Wave 3: T6 (after T2, T3, T3b, T4, T5)
- Wave 4: T7 (after T6)

T2 is in Wave 1 because the path move + env var rename can proceed
independently of the Hermes content work — it only depends on the
existing Claude codebase, which is already complete.

After T3b lands, the workspace owner runs the updated `sync-workspace-rules`
once to materialise `<mgmtRoot>/HERMES.md` for the validation workspace.
This is a one-time setup step per workspace, not a recurring task.

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `workflow` | `mv CLAUDE.shared.md, workflow_skills/, technical_skills/` into `workflow/claude/` | Per-executor staging directory layout |
| `workflow` | New `workflow/hermes/` tree: `SOUL.md`, `HERMES.shared.md`, `workflow_skills/`, `technical_skills/` | Hermes executor staging content |
| `workflow` | `runtime/executors/claude/src/index.ts` — source paths + env var name updates | Adapt to new layout and renamed env var |
| `workflow` | `runtime/executors/hermes/src/index.ts` — new Phase 3.5; drop `--ignore-rules`; set `AGENT_RUNTIME=1`; briefing language update | Hermes setup phase + actually load staged content |
| `workflow` | `runtime/executors/hermes/src/briefing.ts` — skill index + revised scope language | Briefing reflects staged context |
| `workflow` (skills) | `sync-workspace-rules/SKILL.md` — source path update | Read from `workflow/claude/CLAUDE.shared.md` |
| `workflow` (skills) | `start-implementation/SKILL.md`, `pr-create/SKILL.md`, others — `CLAUDE_AGENT_RUNTIME` → `AGENT_RUNTIME` | Env var rename |
| Each project workspace's `CLAUDE.md` | Re-synced via `sync-workspace-rules` after T2 lands | Workspaces pick up the renamed env var |

No changes to: orchestrator, ABI types, any implementation repo, any
management repo workflow/task schema.

---

## 8. Validation and Release Impact

### Testing expectations

- Unit tests for Phase 3.5 (Hermes executor):
  - When `WORKFLOW_LOCAL_PATH` is set and `workflow/hermes/` exists:
    SOUL.md is copied to `~/.hermes/SOUL.md`; skills directories are
    copied to `~/.hermes/skills/`; HERMES.md is written to
    `<implDir>/HERMES.md`; `.git/info/exclude` contains a new line
    matching `^HERMES\.md$`.
  - When `WORKFLOW_LOCAL_PATH` is unset: Phase 3.5 is a no-op; the spawn
    still proceeds (graceful degradation).
  - When any individual source file is missing (SOUL.md present but
    HERMES.shared.md absent, etc.): the present files are still staged;
    no throw.
  - The spawn args do not contain `--ignore-rules`.
  - The spawn env contains `AGENT_RUNTIME=1`.

- Unit tests for the Claude executor:
  - `setupGlobalSkills` reads from `workflow/claude/workflow_skills/`
    and `workflow/claude/technical_skills/` (not the old root paths).
  - Spawn env contains `AGENT_RUNTIME=1` (not `CLAUDE_AGENT_RUNTIME=1`).

- Functional test (impl): a real `kind=impl` Hermes task on a small
  target produces a clean PR (no `HERMES.md` in the file list), commits
  are present, and `result.json` shows `terminal_status: "in_review"`.

- Functional test (review): a real `kind=review` Hermes task posts a
  valid GitHub review and writes `result.json`.

- Identity injection test: an isolated `hermes chat --query "describe your role"` with the
  staged SOUL.md returns a response referencing "headless executor
  mode" or equivalent identity language from SOUL.md.

- Regression test for Claude: existing Claude tasks behave identically.
  Run one impl task and one review task through Claude after T2; confirm
  same output shape as before.

### Backward compatibility

- The path move and env var rename are atomic (one PR). Partial state
  would break the Claude executor; the merge must be all-or-nothing.
- After the PR merges, any existing workspace `CLAUDE.md` referencing
  `CLAUDE_AGENT_RUNTIME` continues to work until `sync-workspace-rules`
  is re-run for that workspace — because the env var is named in
  workspace `CLAUDE.md`, and the executor sets `AGENT_RUNTIME`. So skills
  reading the workspace CLAUDE.md to know what env to check would see
  the old name. Mitigation: T2 includes a follow-up sub-step to
  re-sync the workspace CLAUDE.md for this workspace (and we document
  the same step for other workspaces using this workflow).
- The Hermes executor changes are additive — workspaces that do not run
  Hermes are unaffected.

### Rollout

1. T2 merges (path reorg + env var rename). Claude executor continues
   to work; behaviour is identical to before.
2. T3, T4, T5 merge (Hermes staging content). Hermes still spawns with
   `--ignore-rules` at this point, so no behaviour change.
3. T6 merges (Phase 3.5 + drop `--ignore-rules`). Hermes now loads the
   staged context. Quality improvement is observable from this PR
   onward.
4. T7 runs validation against a real task; if regression vs the current
   broken baseline is detected (unlikely), T6 can be partially reverted
   without touching T2–T5.

The feature can be turned off without removing files: revert just the
`--ignore-rules` removal in T6 and the executor falls back to its
current (limited) behaviour, with staged content harmlessly present
on disk.
