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

Hermes has a skill and context system almost structurally identical to Claude's,
plus one concept Claude does not have (`SOUL.md` for agent identity):

| Concept | Claude | Hermes |
|---|---|---|
| Project rules file | `CLAUDE.md` (auto-injected) | `HERMES.md` / `.hermes.md` / `AGENTS.md` (auto-injected unless `--ignore-rules`) |
| Agent identity file | — (no equivalent; identity baked into briefing) | `~/.hermes/SOUL.md` (auto-injected unless `--ignore-rules`) |
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
    config: [list of config keys]      # optional — config keys this skill needs
    platforms: [platform hints]        # optional — platform compatibility
    requires: [required tools]         # optional — tools or toolsets required
```

Context loading order (auto-injection, highest priority first):
1. `~/.hermes/SOUL.md` (agent identity — global, persona-style)
2. `HERMES.md` / `.hermes.md` (walks to git root from cwd — project rules)
3. `AGENTS.md` / `agents.md` (current dir)
4. `CLAUDE.md` (current dir — Hermes reads this too as a fallback)
5. `.cursorrules`

All files are threat-scanned and truncated to 20,000 chars before injection.

The three layers serve distinct purposes:
- **SOUL.md** answers *"who am I?"* — agent identity, role, behavioural defaults.
  Global; same for every task.
- **HERMES.md** answers *"what rules does this project enforce?"* — workspace
  conventions, code quality rules, MCP lookup priority. Per-workspace; same for
  every task in this workspace.
- **Skills** answer *"what can I do on demand?"* — invocable capabilities (slash
  commands). Per-skill; activated when relevant.

Treating these as separate layers prevents the temptation to dump everything into
one 20,000-char file. Each layer has a focused role; combined they reconstruct the
context Claude gets from CLAUDE.md + skills auto-loading.

---

## 2. Problem Framing

**What specifically needs to change:**

Four things are broken in the current Hermes executor, in order of impact:

1. **`--ignore-rules` disables all native context loading.** Hermes has a context system
   designed to work exactly like Claude's — it just needs to be engaged. The flag
   blocks `SOUL.md`, `HERMES.md`, `AGENTS.md`, `.cursorrules`, memory entries, and
   preloaded skills all at once.

2. **No identity file (`SOUL.md`) exists.** Even with `--ignore-rules` removed,
   Hermes would default to its generic agent identity — it would not know that it is
   operating in headless executor mode, that the wrapper owns git/PR/result.json,
   or how it should differ from a normal Hermes chat session.

3. **`~/.hermes/skills/` is never populated.** Even if `--ignore-rules` were removed,
   Hermes would find no workflow or technical skills because the executor never
   stages them. The Claude executor has an explicit `setupGlobalSkills()` step;
   Hermes has no equivalent.

4. **The briefing contains no workflow guidance or coding standards.** Without
   SOUL.md, HERMES.md, and skills, all guidance must come from the briefing — but
   the current briefing only passes raw task content.

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

- Hermes reads `HERMES.md` from `cwd` upward to the git root at startup — the
  executor must write this file before spawning Hermes.
- Hermes reads `~/.hermes/SOUL.md` at startup for identity injection — the executor
  must write this file before spawning Hermes.
- Hermes discovers `SKILL.md` files from `~/.hermes/skills/` automatically once the
  flag is removed.
- Hermes skills use slash commands identically to Claude (`/skill-name <args>`).
- The Hermes wrapper already owns git push, PR creation, and result.json writing —
  skills for Hermes must NOT include those steps (they are Claude-only concerns in
  the workflow_skills context). Incremental commits *during* implementation are
  allowed and encouraged (crash safety); only the final push and PR are wrapper-owned.
- Writing `HERMES.md` to the impl repo root would normally make it visible to
  `git add -A` in the wrapper's Phase 6, polluting every Hermes PR with the file.
  The executor must add `HERMES.md` to `.git/info/exclude` before Hermes spawn so
  Hermes can still read it while git ignores it locally.
- Memory (Mem0) integration remains out of scope. With `--ignore-rules` removed,
  memory will still be inactive unless `mcp_servers.memory` is configured in
  `HERMES_HOME/config.yaml` — which only `hermes-workspace-memory` does. No
  explicit disable is required, but the executor must not accidentally add a
  memory stanza here.

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
        ├── SOUL.md            # NEW — agent identity (copied to ~/.hermes/SOUL.md)
        └── HERMES.md          # NEW — project rules (copied to taskRepoPath/HERMES.md)

runtime/executors/hermes/src/
├── index.ts                   # CHANGED — new Phase 3.5, drop --ignore-rules, allow incremental commits
└── briefing.ts                # CHANGED — kind-aware (impl vs review); load task-relevant Hermes skill content
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
         copy SOUL.md      → ~/.hermes/SOUL.md          (Hermes injects as identity)
         copy hermes_skills → ~/.hermes/skills/         (Hermes discovers these)
         write HERMES.md   → taskRepoPath/HERMES.md     (Hermes auto-loads from cwd)
         append HERMES.md  → taskRepoPath/.git/info/exclude (local-only ignore — keeps PR clean)
Phase 4: build briefing (expanded, kind-aware)
         → task YAML + tasks section + technical design
         → "Available skills: /start-implementation — ..." (skill index)
         → load task-relevant technical skill content inline (fallback for skills
           not yet ported to hermes_skills/)
         → for kind=review: skip start-implementation; include review-pr instead
Phase 5: spawn hermes chat --query <briefing> --quiet
         (--ignore-rules REMOVED)
         └─ Hermes reads ~/.hermes/SOUL.md → identity in system prompt
         └─ Hermes reads HERMES.md from cwd → workflow rules in system prompt
         └─ Hermes discovers ~/.hermes/skills/ → slash commands available
         └─ /start-implementation runs: read spec → code → test (commits allowed)
         └─ (push, PR, result.json handled by wrapper)
Phase 6: wrapper: stage leftovers + commit + push + open PR + write result.json
```

**The key structural difference:** Claude's skill for `start-implementation` includes
git push, PR creation, and result.json writing. The Hermes version of
`start-implementation` must explicitly **stop** before push/PR/result — the wrapper
owns them. Incremental local commits during the work phase are explicitly allowed
(for crash safety), and the wrapper's Phase 6 catches any leftover unstaged changes
with one final commit before pushing. SOUL.md, HERMES.md, and the skill text must
all reinforce this boundary consistently.

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

#### SOUL.md — the agent identity file

SOUL.md is Hermes-specific — Claude has no equivalent. It is injected at the
*identity* level of the system prompt, separate from project rules. The right
content here is everything that describes *who the agent is* and *how it behaves*,
independent of any workspace.

Because SOUL.md is one global file (lives at `~/.hermes/SOUL.md`), it must be
workspace-agnostic. Workspace-specific rules go into HERMES.md.

Proposed content (concise; well under the 20,000-char limit):

```markdown
# Agent identity

You are an autonomous coding agent operating in headless executor mode for a
workflow-driven engineering workspace. You receive tasks from an orchestrator
and work alone; there is no human in the loop during your run.

## Operating mode

- You are NOT Claude Code, Cursor, or any IDE assistant. There is no chat
  partner. You execute the task and exit.
- You do not ask clarifying questions. Implement exactly what is specified.
- You read the task spec, technical design, and tasks.md section before
  writing any code.
- You commit incrementally with descriptive messages
  (`feat(<featureId>/<taskId>): <what>`) — never batch many changes into one
  giant commit. Crash safety depends on this.
- You run the project's test suite before declaring the work complete.
- You stop cleanly when the work is done. You do not announce completion;
  the wrapper detects your exit.

## Boundary of responsibility

A wrapper process spawned you and will run after you exit. It owns:
- final `git add -A` (catches anything you forgot to stage)
- `git push origin <branch>`
- opening the implementation PR
- writing `result.json`

You must NOT:
- run `git push`
- open a PR
- write a `result.json` file
- modify task YAML files in the management repo

If you try any of these, you are duplicating work the wrapper will do —
and corrupting state if your version disagrees with the wrapper's.

## Tooling reality

- You use the Hermes tool registry (file tools, terminal, etc.).
- You do NOT have Claude's `Read`, `Edit`, `Bash` tools by those names.
- You do NOT have `mcp__<server>__<tool>` prefixed tool names. Use the
  Hermes MCP invocation form for any MCP-backed tool.
```

This content is stable across all workspaces and all task kinds. It changes only
when the executor architecture itself changes (e.g. if a future runtime begins
letting the agent open its own PRs).

#### HERMES.md — the workspace rules file

HERMES.md is the workspace-specific complement to SOUL.md. It carries rules and
conventions that are true *for this workspace*, not for every Hermes session.

Hermes truncates HERMES.md to 20,000 chars on load, so HERMES.md must be a
focused subset — not a copy of the full `CLAUDE.md` (which contains many rules
irrelevant to Hermes's code-only scope and would blow the budget).

It explicitly excludes:
- Task lifecycle / status transition rules (orchestrator handles these)
- Git push / PR protocol (wrapper handles these)
- PR title format rules (wrapper sets the title)
- Slash command catalogue for Claude (replaced with Hermes skill index in the briefing)
- Anything from CLAUDE.md that targets a human operator (e.g. how to run
  `/init-workspace`)

It includes:
- Code quality rules (test-before-declaring-done; lint expectations)
- Workspace-specific coding conventions (file structure, naming, import patterns)
- Checkpoint discipline (commit incrementally — reinforces SOUL.md)
- MCP lookup rules (RAG-first, GitNexus-first — adapted to Hermes MCP syntax)
- Figma propagation rule (when Figma URLs appear in the task — adapted to Hermes
  MCP form for the Figma MCP)
- The repo identity table (which repos exist, which are read-only, which `repo`
  values are valid for `tasks/T<n>.yaml`)

If HERMES.md content approaches 20,000 chars, prefer offloading detail to a
specific skill in `~/.hermes/skills/` and reference the skill by name in
HERMES.md (`see /backend-engineer for backend rules`).

### 4.5 Executor changes

**`runtime/executors/hermes/src/index.ts`** — new Phase 3.5 (runs after Phase 3
writes `HERMES_HOME/config.yaml` and before Phase 4 builds the briefing):

```typescript
// Phase 3.5: Hermes context + skill setup
const workflowLocalPath = process.env.WORKFLOW_LOCAL_PATH ?? "";
if (workflowLocalPath) {
  const templatesDir   = join(workflowLocalPath, "templates", "hermes");
  const hermesSkillsDir = join(workflowLocalPath, "hermes_skills");

  // 3.5a — SOUL.md → ~/.hermes/SOUL.md (agent identity, global)
  const soulSrc = join(templatesDir, "SOUL.md");
  if (existsSync(soulSrc)) {
    copyFileSync(soulSrc, join(hermesHome, "SOUL.md"));
    emit({ type: "phase_done", phase: "3.5a", dest: join(hermesHome, "SOUL.md") });
  }

  // 3.5b — hermes_skills/ → ~/.hermes/skills/ (slash-command skills)
  if (existsSync(hermesSkillsDir)) {
    copyDirRecursive(hermesSkillsDir, join(hermesHome, "skills"));
    emit({ type: "phase_done", phase: "3.5b", dest: join(hermesHome, "skills") });
  }

  // 3.5c — HERMES.md → implDir/HERMES.md (workspace rules, auto-loaded from cwd)
  const hermesMdSrc = join(templatesDir, "HERMES.md");
  if (existsSync(hermesMdSrc)) {
    copyFileSync(hermesMdSrc, join(implDir, "HERMES.md"));

    // 3.5d — Add HERMES.md to .git/info/exclude so the wrapper's Phase 6
    // git add -A does not stage it. This is local-only (does not touch the
    // repo's .gitignore) and keeps every Hermes PR free of the file.
    const excludePath = join(implDir, ".git", "info", "exclude");
    if (existsSync(dirname(excludePath))) {
      appendFileSync(excludePath, "\n# Hermes executor — auto-loaded workspace rules\nHERMES.md\n");
    }
    emit({ type: "phase_done", phase: "3.5c", dest: join(implDir, "HERMES.md") });
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

Removing `--ignore-rules` unblocks four things at once: SOUL.md, HERMES.md,
`~/.hermes/skills/` discovery, and memory entries. Memory is intentionally
inert because `HERMES_HOME/config.yaml` does not declare a memory backend in
this feature's scope (`hermes-workspace-memory` adds that separately).

**Briefing scope language must change** (`buildBriefing()`):

The current closing line of the briefing reads:

> *"Make the required code changes and save the files. Do not commit, push, open a
> pull request, or write any result file — those steps are handled outside your
> session. When your changes are saved, you are done."*

This is too restrictive. **Local commits during work are valuable** (crash safety,
incremental reviewability) — the wrapper's Phase 6 already does a final
`git add -A` to catch any unstaged residue. The new language should read:

> *"Make the required code changes and commit them incrementally on the current
> branch with `feat(<featureId>/<taskId>): <what>` messages. Do NOT run
> `git push`, do NOT open a pull request, and do NOT write any result file —
> the wrapper handles those steps after you exit. Run the project's test suite
> before you stop. When tests pass, exit cleanly — do not announce completion."*

**`runtime/executors/hermes/src/briefing.ts`** — kind-aware briefing:

`buildBriefing()` gains a `kind` parameter (`"impl" | "review"`) so it can
load the right skill set and emit the right scope language. For `kind="review"`
it includes the PR diff and references `/review-pr` instead of
`/start-implementation`. The current code base already has a parallel review
path for Hermes (delivered by `executor-capability`); T6 verifies and updates
both.

The briefing gains two new sections after the task context:
- `## Available skills` — a short index of `/skill-name — description` for each skill
  in `~/.hermes/skills/`. Built by scanning the staged skill directory and reading
  each SKILL.md's frontmatter (`name`, `description`).
- `## Technical guidance` — inlined content of technical skills declared in
  tasks.md's `### Required skills` for this task that are not yet ported to
  `hermes_skills/`. This is the fallback path during the rollout: portable
  skills get ported gradually, and any not-yet-ported skill is inlined from
  `technical_skills/<slug>/SKILL.md`.

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
| Hermes skill frontmatter required values | unresolved | T1 must confirm exact `metadata.hermes.requires` tool names (`terminal`, `file_tools`, etc.) before T4 commits to a frontmatter format |
| `--ignore-rules` regression risk | low | SOUL.md + HERMES.md + `~/.hermes/skills/` must land in the same PR as the flag removal; T6 enforces this |
| Memory accidentally activates after flag removal | low | `HERMES_HOME/config.yaml` (Phase 3) is the only enable path; it does not declare a memory backend in this feature. `hermes-workspace-memory` adds the backend separately. |

**Unresolved items (must close in T1 before downstream tasks proceed):**

- Exact Hermes MCP tool invocation syntax for `gitnexus` and `rag` MCP servers.
  Docs describe an `mcp_tool.py` abstraction but not the user-visible call form.
  Resolution path: run `hermes chat --query "list tools"` in a sandbox with the
  MCP servers configured, observe the tool names and call shape, document in
  `docs/features/hermes-skill-adaptation/audit.md`.
- Exact `metadata.hermes.requires` schema — confirm valid tool-name values for
  `terminal`, file operations, and MCP-dependent skills.
- Behaviour when SOUL.md AND HERMES.md AND CLAUDE.md all exist at once.
  Hermes's loading order lists CLAUDE.md as a fallback — we want HERMES.md to
  take precedence over any stray CLAUDE.md left in the impl repo. T1 confirms
  by inspection or probe.

---

## 6. Parallelization / Blocking Analysis

```
T1: Skill gap audit — classify all skills, write audit.md, probe Hermes MCP syntax
    and frontmatter schema, verify HERMES.md precedence over CLAUDE.md
  └── Can begin now — no blockers
  │
T2: SOUL.md + HERMES.md templates + hermes_skills/ scaffold
    (templates/hermes/SOUL.md, templates/hermes/HERMES.md, hermes_skills/ dir
     with placeholder files)
  └── Can begin now — no blockers (structure is independent of audit results;
       SOUL.md content is workspace-agnostic and drafted in 4.4 already)
  │
  T3: Hermes-variant core workflow skills (start-implementation, review-pr)
      └── BLOCKED on T1 (audit must confirm tool name references and scope boundary)
      └── BLOCKED on T2 (hermes_skills/ directory must exist)
      T3 and T4 run in parallel
  │
  T4: Portable technical skills — copy + frontmatter update
      └── BLOCKED on T1 (frontmatter `metadata.hermes.requires` schema must be pinned)
      └── BLOCKED on T2 (hermes_skills/ directory must exist)
      T4 can begin as soon as T1 + T2 are done
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
| `workflow` | Add `hermes_skills/` directory tree | Native Hermes skill discovery |
| `workflow` | Add `templates/hermes/SOUL.md` | Agent identity (no Claude equivalent) |
| `workflow` | Add `templates/hermes/HERMES.md` | Workspace rules file (Hermes equivalent of CLAUDE.md, focused subset) |
| `workflow` | `runtime/executors/hermes/src/index.ts` — Phase 3.5 added; `--ignore-rules` removed; briefing-spawn cwd unchanged | Executor stages SOUL.md + skills + HERMES.md and enables auto-loading |
| `workflow` | `runtime/executors/hermes/src/briefing.ts` — kind-aware (impl vs review); skills index + technical skill inline sections; revised scope language permitting incremental commits | Briefing expansion |

No changes to: orchestrator, Claude executor, ABI types, management repo structure,
or any implementation repos.

---

## 8. Validation and Release Impact

### Testing expectations

- Unit tests for Phase 3.5 in `runtime/executors/hermes/src/index.test.ts`:
  - SOUL.md copied to `~/.hermes/SOUL.md` when `WORKFLOW_LOCAL_PATH` is set
  - `hermes_skills/` copied to `~/.hermes/skills/` when `WORKFLOW_LOCAL_PATH` is set
  - HERMES.md written to task repo root
  - HERMES.md appended to `.git/info/exclude` (verify with regex match on the file)
  - `--ignore-rules` absent from spawn args
  - Phase 3.5 is a no-op (no throw, no partial write) when `WORKFLOW_LOCAL_PATH` is unset
  - Phase 3.5 is a no-op for any file that doesn't exist in `templates/hermes/`
    (graceful degradation — never block the spawn on a missing template)

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

- PR cleanliness test: after a successful Hermes impl run, inspect the resulting
  PR. Confirm the PR's file list does NOT contain `HERMES.md` — the
  `.git/info/exclude` entry must have kept it out of `git add -A`. A regression
  here pollutes every Hermes PR with the rules file.

- Identity injection test: spawn Hermes with `--query "describe your role in one sentence"`
  in a sandbox using the staged SOUL.md. The response should reference "headless
  executor mode" or equivalent identity language from SOUL.md — proves the file
  is being read.

### Backward compatibility

- The Claude executor is entirely unchanged — no regression risk.
- The `--ignore-rules` removal only affects Hermes spawns. Hermes behaviour with
  context files enabled is well-defined; SOUL.md, HERMES.md, and skills will all
  be in place before the flag is removed (Phase 3.5 runs before Phase 5).
- `WORKFLOW_LOCAL_PATH` is optional: if absent, Phase 3.5 is a no-op and the executor
  falls back to the current (limited) behaviour. No hard failure on missing path.
- Each Phase 3.5 sub-step (`3.5a`, `3.5b`, `3.5c`, `3.5d`) is independently
  guarded by `existsSync` — a partial install (e.g. SOUL.md present but HERMES.md
  missing) still works for whichever pieces are available.

### Rollout

No orchestrator config changes required. Operators who run Hermes tasks need to set
`WORKFLOW_LOCAL_PATH` in `extraEnv` for the Hermes executor profile if not already
set. This is a one-line change to the orchestrator config file — not a code change.

The feature can be toggled off by reverting to `--ignore-rules` without touching skill
files. Skill files are additive and cause no harm when present.
