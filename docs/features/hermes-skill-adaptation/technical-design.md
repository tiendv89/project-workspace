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

### 4.2 Setup-phase responsibility (per executor)

**Claude executor setup (unchanged behaviour, new paths):**

| Step | Source | Destination |
|---|---|---|
| copy CLAUDE.md | `<mgmt>/CLAUDE.md` (generated from `workflow/claude/CLAUDE.shared.md` via `sync-workspace-rules`) | `~/.claude/CLAUDE.md` |
| copy skills | `workflow/claude/workflow_skills/`, `workflow/claude/technical_skills/`, `<mgmt>/.claude/skills/` | `~/.claude/skills/` |
| copy settings | `workflow/templates/claude-settings.json` | `~/.claude/settings.json` |
| env var | — | spawn with `AGENT_RUNTIME=1` (renamed from `CLAUDE_AGENT_RUNTIME=1`) |

**Hermes executor setup (new Phase 3.5):**

| Step | Source | Destination |
|---|---|---|
| copy SOUL.md | `workflow/hermes/SOUL.md` | `~/.hermes/SOUL.md` |
| copy skills | `workflow/hermes/workflow_skills/`, `workflow/hermes/technical_skills/` | `~/.hermes/skills/` |
| copy HERMES.md | `workflow/hermes/HERMES.shared.md` | `<implDir>/HERMES.md` |
| exclude HERMES.md | — | append `HERMES.md` to `<implDir>/.git/info/exclude` |
| env var | — | spawn with `AGENT_RUNTIME=1` |
| spawn args | — | drop `--ignore-rules` so Hermes auto-loads the staged content |

Both wrappers behave identically structurally: a setup phase that copies a
small set of files from `workflow/<self>/` into the agent's native locations,
then the spawn. The wrappers do not read each other's directories and have
no shared imports for staging logic.

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
- Tooling reality (use the Hermes tool registry; no Claude tool names; no
  `mcp__server__tool` prefix; use Hermes MCP invocation form)

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
const workflowLocalPath = process.env.WORKFLOW_LOCAL_PATH ?? "";
if (workflowLocalPath) {
  const hermesSrc = join(workflowLocalPath, "hermes");

  // 3.5a — SOUL.md → ~/.hermes/SOUL.md
  const soulSrc = join(hermesSrc, "SOUL.md");
  if (existsSync(soulSrc)) {
    copyFileSync(soulSrc, join(hermesHome, "SOUL.md"));
  }

  // 3.5b — workflow_skills/ + technical_skills/ → ~/.hermes/skills/
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

  // 3.5c — HERMES.shared.md → implDir/HERMES.md (auto-loaded by Hermes from cwd)
  const hermesMdSrc = join(hermesSrc, "HERMES.shared.md");
  if (existsSync(hermesMdSrc)) {
    copyFileSync(hermesMdSrc, join(implDir, "HERMES.md"));

    // 3.5d — local-only ignore so Phase 6 git add -A does not stage HERMES.md
    const excludePath = join(implDir, ".git", "info", "exclude");
    if (existsSync(dirname(excludePath))) {
      appendFileSync(excludePath, "\n# Hermes auto-loaded workspace rules\nHERMES.md\n");
    }
  }

  emit({ type: "phase_done", phase: 3.5, hermes_src: hermesSrc });
}
```

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
| Hermes MCP invocation syntax | unresolved | T1 audit confirms exact form before T6 writes Hermes MCP skills |
| Hermes skill frontmatter (`metadata.hermes.requires`) values | unresolved | T1 audit confirms exact tool-name strings |
| `sync-workspace-rules` reads new path | resolved in T2 | Path change is part of the move task |
| `AGENT_RUNTIME` rename does not break old skills | resolved in T2 | Atomic rename across all referencing files in one PR |

**Unresolved items (must close in T1 before downstream tasks):**

- Exact Hermes MCP invocation syntax for `gitnexus` and `rag` servers.
- Exact Hermes skill frontmatter required-tool values.
- Confirm: does Hermes loading `HERMES.md` from cwd respect `.git/info/exclude`?
  (i.e. does Hermes read the file? — yes, the exclude is a git-side
  mechanism that does not affect file readability.) This is a sanity check,
  not a real risk.

---

## 6. Parallelization / Blocking Analysis

```
T1: Audit
    Probe Hermes MCP syntax, frontmatter schema, HERMES.md vs CLAUDE.md
    precedence; produce audit.md.
  └── Can begin now — no blockers

T2: Workflow repo reorg + AGENT_RUNTIME rename (single atomic PR)
    - mv workflow/CLAUDE.shared.md      → workflow/claude/CLAUDE.shared.md
    - mv workflow/workflow_skills/      → workflow/claude/workflow_skills/
    - mv workflow/technical_skills/     → workflow/claude/technical_skills/
    - Update Claude executor index.ts: source paths + env var name
    - Update sync-workspace-rules skill: source path
    - Rename CLAUDE_AGENT_RUNTIME → AGENT_RUNTIME everywhere
    - Update CLAUDE.shared.md "Agent-runtime detection rule" text
  └── Can begin now — no blockers
  └── Must land as one PR; partial state breaks the Claude executor.

T3: workflow/hermes/SOUL.md + HERMES.shared.md authoring
  └── Can begin now — content is workspace-agnostic; covered in §4.4
  └── No code dependency on T1 or T2

T4: workflow/hermes/workflow_skills/ — Hermes-flavoured workflow skills
    (start-implementation, rag-context, review-pr)
  └── BLOCKED on T1 (need MCP invocation form for rag-context;
       need confirmed scope boundary for start-implementation/review-pr)

T5: workflow/hermes/technical_skills/ — Hermes-flavoured technical skills
    (backend-engineer, typescript-best-practices, go-best-practices,
    python-best-practices, gitnexus-mcp, frontend-engineer)
  └── BLOCKED on T1 (need MCP form for gitnexus-mcp; need confirmed
       frontmatter schema for all)

T6: Hermes executor Phase 3.5 implementation
    - index.ts: copy SOUL.md, skills, HERMES.md
    - index.ts: append HERMES.md to .git/info/exclude
    - index.ts: drop --ignore-rules; set AGENT_RUNTIME=1
    - briefing.ts: skill index + revised scope language
    - Unit tests
  └── BLOCKED on T2 (Claude executor must have already moved to
       AGENT_RUNTIME=1 — keeps both executors aligned in one direction)
  └── BLOCKED on T3 (SOUL.md + HERMES.shared.md must exist to copy)
  └── BLOCKED on T4, T5 (skills must exist to copy)

T7: Validation — real impl + real review task on Hermes, before/after quality comparison
  └── BLOCKED on T6
```

**Wave ordering:**
- Wave 1 (parallel): T1, T2, T3
- Wave 2 (parallel): T4, T5 (after T1 finishes)
- Wave 3: T6 (after T2, T3, T4, T5)
- Wave 4: T7 (after T6)

T2 is in Wave 1 because the path move + env var rename can proceed
independently of the Hermes content work — it only depends on the
existing Claude codebase, which is already complete.

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
