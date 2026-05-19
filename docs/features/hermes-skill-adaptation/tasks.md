# Task Breakdown — hermes-skill-adaptation

**Feature status:** `in_tdd` | **Stage:** `tasks` (awaiting approval)
Machine-mutable state (status, log, PR, branch) lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on | Repo |
|---|---|---|---|---|
| T1 | 1 | Skill classification audit + precedence note | — | management-repo |
| T2 | 1 | Workflow repo reorg + AGENT_RUNTIME rename (atomic) | — | workflow |
| T3 | 1 | `workflow/hermes/SOUL.md` + `HERMES.shared.md` authoring | — | workflow |
| T4 | 2 | Extend `sync-workspace-rules` with HERMES.md Step B | T2, T3 | workflow |
| T5 | 1 | `workflow/hermes/workflow_skills/` — start-implementation, rag-context, review-pr | — | workflow |
| T6 | 1 | `workflow/hermes/technical_skills/` — backend, TS, Go, Python, gitnexus-mcp, frontend | — | workflow |
| T7 | 3 | Hermes executor Phase 3.5 + spawn changes + `.env.template` + tests | T2, T3, T4, T5, T6 | workflow |
| T8 | 4 | Validation — real impl + real review, before/after comparison | T7 | management-repo |

## Dependency diagram

```
T1: Skill classification audit + precedence note (mgmt repo)
  └── Can begin now — no blockers
  │
T2: Workflow repo reorg + AGENT_RUNTIME rename (workflow repo, atomic PR)
  └── Can begin now — no blockers
  │
T3: workflow/hermes/SOUL.md + HERMES.shared.md authoring (workflow repo)
  └── Can begin now — content is workspace-agnostic; MCP names already resolved in design §5
  │
T5: workflow/hermes/workflow_skills/ — Hermes-flavoured workflow skills (workflow repo)
T6: workflow/hermes/technical_skills/ — Hermes-flavoured technical skills (workflow repo)
  └── T5 and T6 run in parallel with T1, T2, T3
  └── Can begin now — MCP invocation form (mcp_<server>_<tool>) and frontmatter
       schema (requires_toolsets / requires_tools) already resolved in design §5
  │
  T4: Extend sync-workspace-rules with HERMES.md Step B (workflow repo)
      └── BLOCKED on T2 (skill source path for CLAUDE.shared.md moves in T2)
      └── BLOCKED on T3 (HERMES.shared.md must exist to sync from)
      │
      T7: Hermes executor Phase 3.5 + spawn changes + .env.template + tests (workflow repo)
          └── BLOCKED on T2 (Claude executor must already be on AGENT_RUNTIME=1
                — keeps both executors aligned in the same direction)
          └── BLOCKED on T3 (SOUL.md + HERMES.shared.md must exist to stage)
          └── BLOCKED on T4 (workspace HERMES.md must be reachable via the
                extended sync skill — otherwise Phase 3.5c has nothing to copy)
          └── BLOCKED on T5, T6 (Hermes skill files must exist to stage to
                ~/.hermes/skills/)
          │
          T8: Validation — real Hermes impl + review run, before/after comparison
              └── BLOCKED on T7 (executor must be deployed with Phase 3.5
                    active before validation can run)
```

**Wave summary:**
- **Wave 1 (parallel)**: T1, T2, T3, T5, T6
- **Wave 2**: T4 (after T2 + T3)
- **Wave 3**: T7 (after T2, T3, T4, T5, T6)
- **Wave 4**: T8 (after T7)

After T4 lands, the workspace owner runs the extended `sync-workspace-rules` once
to materialise `<mgmtRoot>/HERMES.md` in the validation workspace. This is a
one-time setup step per workspace, not a recurring task.

---

## T1 — Skill classification audit + precedence note

### Description

Produce `docs/features/hermes-skill-adaptation/audit.md` containing:

1. **Per-skill classification table** — every directory under
   `workflow/technical_skills/` and `workflow/workflow_skills/` classified as
   `portable | adapt | hermes-variant`:
   - `portable` — content works as-is for Hermes (pure coding standards, no
     Claude-specific syntax)
   - `adapt` — minor edits needed (Claude tool name mentions, `mcp__` prefix
     references)
   - `hermes-variant` — needs a Hermes-specific version (different flow,
     different scope; e.g. `start-implementation`, `pr-create`, MCP-bound skills)

   The classification informs T5/T6 content work — which Claude skill files to
   start from as a base for the Hermes version.

2. **HERMES.md vs CLAUDE.md precedence inspection note** — document Hermes's
   behaviour when both files exist in the same cwd. Either reproduce by spawning
   a Hermes session in a sandbox dir with both files present and observing which
   wins, or record "not reproduced — document by reading Hermes source"
   referencing the relevant `agent/prompt_builder.py` lookup order. This is a
   sanity check, not a feature dependency.

The audit lives in the management repo (`docs/features/hermes-skill-adaptation/audit.md`).
It does not touch the workflow repo.

### Required skills
- rag-context

### Subtasks
- [ ] List every directory under `workflow/technical_skills/` and `workflow/workflow_skills/`
- [ ] For each skill, read SKILL.md and classify based on presence of:
      slash command references (`/pr-create`, `/start-implementation`),
      `mcp__<server>__<tool>` prefix references, `CLAUDE_AGENT_RUNTIME` env var,
      Claude built-in tool names (`Read`, `Edit`, `Bash`, `WebFetch`)
- [ ] Write classification table in `audit.md` with one row per skill: slug, classification, rationale
- [ ] Inspect or reproduce HERMES.md vs CLAUDE.md precedence; record finding
- [ ] Commit `audit.md` to the feature branch in the management repo
- [ ] Open PR

---

## T2 — Workflow repo reorg + AGENT_RUNTIME rename (atomic)

### Description

Atomic restructuring of the workflow repo so each executor has its own
content-staging directory:

- Move `workflow/CLAUDE.shared.md` → `workflow/claude/CLAUDE.shared.md`
- Move `workflow/workflow_skills/` → `workflow/claude/workflow_skills/`
- Move `workflow/technical_skills/` → `workflow/claude/technical_skills/`
- Rename `CLAUDE_AGENT_RUNTIME` → `AGENT_RUNTIME` everywhere it appears
- Update Claude executor source paths to read from `claude/workflow_skills/` and
  `claude/technical_skills/`
- Update Claude executor spawn env var name
- Update Claude executor tests for path + env-var name
- Update `sync-workspace-rules` skill source path for `CLAUDE.shared.md`
- Update `workflow/scripts/bootstrap.sh` and `workflow/scripts/install.sh` path
  strings (both reference `workflow_skills/` and `technical_skills/` directly)
- Update `workflow/README.md` path references (lines 7, 8, 46)
- Update `workflow/claude/CLAUDE.shared.md` after the move: rename
  `CLAUDE_AGENT_RUNTIME` mention on line ~504 to `AGENT_RUNTIME`; update the two
  path mentions (lines 424, 446)
- Inspect `runtime/orchestrator/templates/docker-compose.yml` and
  `docker-compose.local-docker.yml` for any `CLAUDE_AGENT_RUNTIME` literal
  (expected: none — orchestrator passes env via `SubProcessAdapter.extraEnv`)
- Inspect `runtime/orchestrator/docs/OPERATOR-GUIDE.md` for stale paths/env var

**This must land as one atomic PR.** A partial state breaks the Claude executor.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] `git mv workflow/CLAUDE.shared.md workflow/claude/CLAUDE.shared.md`
- [ ] `git mv workflow/workflow_skills workflow/claude/workflow_skills`
- [ ] `git mv workflow/technical_skills workflow/claude/technical_skills`
- [ ] Update `workflow/claude/CLAUDE.shared.md`: rename `CLAUDE_AGENT_RUNTIME` →
      `AGENT_RUNTIME` (1 mention on line ~504); update 2 path mentions
      (lines 424, 446) — `workflow/technical_skills/` → `workflow/claude/technical_skills/`
- [ ] `grep -r CLAUDE_AGENT_RUNTIME workflow/claude/workflow_skills` and rename
      each occurrence to `AGENT_RUNTIME` (expected files: `start-implementation/SKILL.md`,
      `pr-create/SKILL.md`)
- [ ] Update `workflow/claude/workflow_skills/sync-workspace-rules/SKILL.md`:
      change source path of CLAUDE.shared.md to `workflow/claude/CLAUDE.shared.md`
- [ ] Update `runtime/executors/claude/src/index.ts`:
      `setupGlobalSkills` paths → `join(workflowLocalPath, "claude", "technical_skills")`
      and `join(workflowLocalPath, "claude", "workflow_skills")`;
      spawn env var: `CLAUDE_AGENT_RUNTIME` → `AGENT_RUNTIME`
- [ ] Update Claude executor tests (`runtime/executors/claude/src/*.test.ts`)
      for path strings and env-var assertions
- [ ] Update `workflow/scripts/bootstrap.sh`:
      `WORKFLOW_SKILLS_DIR="$WORKFLOW_ROOT/claude/workflow_skills"`
- [ ] Update `workflow/scripts/install.sh`:
      `SHARED_WORKFLOW_SKILLS_DIR="$SHARED_ROOT/claude/workflow_skills"`,
      `SHARED_TECHNICAL_SKILLS_DIR="$SHARED_ROOT/claude/technical_skills"`,
      plus the error/skip messages referencing those paths
- [ ] Update `workflow/README.md`: lines 7, 8, 46 — path references now under `claude/`
- [ ] Inspect `runtime/orchestrator/templates/docker-compose.yml` and
      `docker-compose.local-docker.yml` for `CLAUDE_AGENT_RUNTIME`; no edit
      expected — record inspection result in PR description
- [ ] Inspect `runtime/orchestrator/docs/OPERATOR-GUIDE.md`; edit if affected
- [ ] Run full Claude executor test suite — must all pass
- [ ] Run any workflow-repo lint / typecheck
- [ ] Open single atomic PR titled `chore(workflow): reorg into per-executor dirs + AGENT_RUNTIME rename`

---

## T3 — `workflow/hermes/SOUL.md` + `HERMES.shared.md` authoring

### Description

Create the two Hermes context files in the workflow repo:

- `workflow/hermes/SOUL.md` — agent identity (workspace-agnostic). Content per
  technical design §4.4: operating mode, boundary of responsibility, tooling
  reality. Tooling reality MUST explicitly mention the available MCPs (`rag`,
  `gitnexus`) and Hermes's `mcp_<server>_<tool>` invocation form (resolved in
  design §5).
- `workflow/hermes/HERMES.shared.md` — workspace rules template. Content per
  technical design §4.4: code quality, conventions, checkpoint discipline, MCP
  lookup rules (RAG-first, GitNexus-first using `mcp_rag_rag_query` and
  `mcp_gitnexus_query`), repo identity reminder. Stay well under 20,000 chars.
  Must include `<!-- BEGIN SHARED WORKFLOW RULES -->` /
  `<!-- END SHARED WORKFLOW RULES -->` markers around the synced section so
  T4's `sync-workspace-rules` extension can find them.

Neither file requires the audit (T1) to be complete — content is workspace-agnostic.

### Required skills
- (none — markdown authoring)

### Subtasks
- [ ] Create directory `workflow/hermes/`
- [ ] Author `workflow/hermes/SOUL.md` (target ~80–150 lines):
      operating mode (headless, no human-in-the-loop, no clarifying questions);
      boundary of responsibility (wrapper owns git push, PR, result.json;
      agent owns code + tests + incremental local commits);
      tooling reality (Hermes tool registry; MCPs available — `mcp_rag_rag_query`,
      `mcp_gitnexus_query`, `mcp_gitnexus_context`, `mcp_gitnexus_impact`,
      `mcp_gitnexus_detect_changes`; NO Claude tool names; NO `mcp__` prefix)
- [ ] Author `workflow/hermes/HERMES.shared.md` (target ~200–400 lines, well
      under 20,000 chars):
      code quality (test-before-declaring-done; lint expectations);
      conventions (commit message format, file structure, naming);
      checkpoint discipline (commit incrementally, never batch);
      MCP lookup priority (RAG-first for project knowledge, GitNexus-first for
      structural code questions, using Hermes invocation form);
      repo identity reminder (which repo this task targets)
- [ ] Wrap the synced section in `<!-- BEGIN SHARED WORKFLOW RULES -->` /
      `<!-- END SHARED WORKFLOW RULES -->` markers (T4 depends on these)
- [ ] Verify both files render correctly and are ASCII-safe
- [ ] Open PR

---

## T4 — Extend `sync-workspace-rules` with HERMES.md Step B

### Description

Add a second sync pass to the `sync-workspace-rules` skill (now living at
`workflow/claude/workflow_skills/sync-workspace-rules/SKILL.md` after T2) so
each workspace's HERMES.md is generated and kept aligned with the workflow
template, mirroring the existing CLAUDE.md flow.

Per technical design §4.7:
- **Step A (existing)**: sync `<projectRoot>/CLAUDE.md` from
  `workflow/claude/CLAUDE.shared.md` between markers
- **Step B (new)**: sync `<projectRoot>/HERMES.md` from
  `workflow/hermes/HERMES.shared.md` between markers; create the file if
  absent; degrade gracefully (no-op + emit warning event) if HERMES.shared.md
  does not exist

Both steps run on every invocation. They are independent — Step B failure
must not break Step A and vice versa.

### Required skills
- (none — markdown skill editing)

### Subtasks
- [ ] Read `workflow/claude/workflow_skills/sync-workspace-rules/SKILL.md`
      (post-T2 location) to understand current Step A structure
- [ ] Add `## Step B — HERMES.md sync` section mirroring Step A's "Read / Compare
      / Update" sub-structure
- [ ] Document the "create HERMES.md from template if absent" path: when
      `<projectRoot>/HERMES.md` doesn't exist, the skill creates it with the
      template:
      `# <project name> — Hermes operating rules\n<!-- BEGIN SHARED WORKFLOW RULES -->\n<content>\n<!-- END SHARED WORKFLOW RULES -->\n`
- [ ] Document graceful no-op when `workflow/hermes/HERMES.shared.md` absent
- [ ] Update path resolution section if needed (add HERMES.shared.md path
      alongside CLAUDE.shared.md)
- [ ] Update the skill's `## Must preserve` and tool-usage notes for Step B
      symmetric with Step A
- [ ] Open PR

---

## T5 — `workflow/hermes/workflow_skills/`

### Description

Create three Hermes-flavoured workflow skills under
`workflow/hermes/workflow_skills/`:

- `start-implementation/SKILL.md` — read spec, implement, run tests, commit
  incrementally on the current branch. **STOP** before `git push` / PR
  creation / `result.json` (the wrapper handles those — boundary defined in
  SOUL.md and HERMES.md).
- `rag-context/SKILL.md` — RAG pre-flight pattern using `mcp_rag_rag_query`
  (Hermes invocation form, NOT Claude's `mcp__rag-server__rag_query`).
- `review-pr/SKILL.md` — read PR diff, evaluate against task spec and
  technical design, output structured review commentary. **STOP** before
  posting the GitHub review or writing result.json (wrapper handles both).

All three SKILL.md files use Hermes frontmatter:
`metadata.hermes.requires_toolsets: [...]` per design §5.

These skills are NEW files — written specifically for Hermes's instruction
style. Do NOT copy Claude versions and patch; author from scratch using the
Hermes scope-boundary pattern.

### Required skills
- (none — markdown authoring)

### Subtasks
- [ ] Create directory `workflow/hermes/workflow_skills/`
- [ ] Author `start-implementation/SKILL.md`:
      Step 1 read spec (task YAML, tasks.md section, technical-design.md);
      Step 2 implement (file tools, terminal); commit incrementally with
      `feat(<featureId>/<taskId>): <what>`;
      Step 3 run tests; Step 4 STOP (no push, no PR, no result.json — wrapper handles)
- [ ] Author `rag-context/SKILL.md`: query pattern via `mcp_rag_rag_query`;
      when to use; example arguments; never re-query the runtime's pre-flight
      query for the same task title
- [ ] Author `review-pr/SKILL.md`: read PR diff; evaluate against spec + tech
      design + rubric; output structured commentary; STOP before GitHub API
      call or result.json write (wrapper handles)
- [ ] Add Hermes frontmatter to each: `metadata.hermes.requires_toolsets:`
      with appropriate values (e.g. `[terminal, file]` for start-implementation;
      `[]` or just web for rag-context)
- [ ] Open PR

---

## T6 — `workflow/hermes/technical_skills/`

### Description

Create six Hermes-flavoured technical skills under
`workflow/hermes/technical_skills/`. Initial focus on highest-leverage skills
(most-used in real tasks). Additional skills can be added incrementally in
follow-up PRs.

- `backend-engineer/SKILL.md` — backend engineering rules (compatibility,
  versioning, distributed cron safety). Mostly portable from Claude version,
  with Hermes frontmatter.
- `typescript-best-practices/SKILL.md` — TypeScript idioms, advanced types,
  patterns. Mostly portable.
- `go-best-practices/SKILL.md` — Go idioms, error handling, concurrency.
  Mostly portable.
- `python-best-practices/SKILL.md` — Pythonic idioms, type hints, PEP 8.
  Mostly portable.
- `gitnexus-mcp/SKILL.md` — code-graph lookup priority rule, with Hermes MCP
  invocation form: `mcp_gitnexus_query`, `mcp_gitnexus_context`,
  `mcp_gitnexus_impact`, `mcp_gitnexus_detect_changes`. NEEDS rewriting (the
  Claude version uses `mcp__gitnexus__*`).
- `frontend-engineer/SKILL.md` — frontend engineering guidance.
  Mostly portable.

All SKILL.md files use Hermes frontmatter
(`metadata.hermes.requires_toolsets: [terminal, file]` is the typical value).

For portable skills, the starting point is the Claude version (post-T2 at
`workflow/claude/technical_skills/<slug>/SKILL.md`). Update only:
- Frontmatter (Claude → Hermes form)
- Any Claude tool-name references (`Read`, `Edit`, `Bash`)
- Any `mcp__<server>__<tool>` references → Hermes invocation form

For `gitnexus-mcp` (hermes-variant), author fresh using the resolved tool names.

### Required skills
- (none — markdown authoring)

### Subtasks
- [ ] Create directory `workflow/hermes/technical_skills/`
- [ ] Author `backend-engineer/SKILL.md` (copy + frontmatter update)
- [ ] Author `typescript-best-practices/SKILL.md` (copy + frontmatter update)
- [ ] Author `go-best-practices/SKILL.md` (copy + frontmatter update)
- [ ] Author `python-best-practices/SKILL.md` (copy + frontmatter update)
- [ ] Author `gitnexus-mcp/SKILL.md` — REWRITE with Hermes MCP form:
      `mcp_gitnexus_query`, `mcp_gitnexus_context`, `mcp_gitnexus_impact`,
      `mcp_gitnexus_detect_changes`. Lookup priority rule (use GitNexus
      before grep for structural questions).
- [ ] Author `frontend-engineer/SKILL.md` (copy + frontmatter update)
- [ ] Add `metadata.hermes.requires_toolsets:` to every file
- [ ] Open PR

---

## T7 — Hermes executor Phase 3.5 + spawn changes + `.env.template` + tests

### Description

Implement the Hermes executor changes that activate everything T2–T6 staged:

- Add Phase 3.5 to `runtime/executors/hermes/src/index.ts` per design §4.5:
  copy SOUL.md to `~/.hermes/SOUL.md`; copy skills to `~/.hermes/skills/`;
  copy `<mgmtDir>/HERMES.md` to `<implDir>/HERMES.md`; append `HERMES.md` to
  `<implDir>/.git/info/exclude`. All sub-steps independently guarded by
  `existsSync` — partial install (e.g. SOUL.md present but HERMES.md missing)
  still produces a working spawn for whichever pieces exist.
- Drop `--ignore-rules` from the spawn args.
- Set `AGENT_RUNTIME=1` in the spawn env (the renamed env var from T2).
- Extend `writeHermesConfig()` to accept `gitnexusMcpUrl` and write the
  `gitnexus` MCP stanza in `HERMES_HOME/config.yaml` (mirroring the existing
  `rag` stanza).
- Read `GITNEXUS_MCP_URL` from the process env in `main()` and pass it to
  `writeHermesConfig()`.
- Update `runtime/executors/hermes/src/briefing.ts` per design §4.5:
  add `## Available skills` section listing slash commands in `~/.hermes/skills/`;
  revise scope language to permit incremental commits while still forbidding
  push / PR / result.json.
- Update test files: `hermes-config.test.ts` (gitnexus stanza assertions);
  `briefing.test.ts` (skill index + revised scope language assertions); new
  `phase3_5.test.ts` (file staging + `.git/info/exclude` append).
- Update `workflow/.env.template` with documented entries:
  `HERMES_INFERENCE_MODEL`, `HERMES_INFERENCE_PROVIDER`, `HERMES_MAX_TURNS`,
  `RAG_MCP_URL`, `RAG_MCP_TOKEN`, `GITNEXUS_MCP_URL`.
- Inspect docker-compose templates — expected no-op since Hermes runs as a
  SubProcess from the orchestrator (no separate Hermes service block).
  Document the inspection result.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Implement Phase 3.5 body in `runtime/executors/hermes/src/index.ts`
      (sub-steps 3.5a–3.5d per design §4.5 code block)
- [ ] Drop `--ignore-rules` from `spawnHermes()` args array
- [ ] Set `AGENT_RUNTIME: "1"` in `spawnHermes()` env block
- [ ] Extend `HermesConfig` interface and `writeHermesConfig()` to accept and
      write `gitnexusMcpUrl` stanza
- [ ] Read `GITNEXUS_MCP_URL` env var in `main()`; pass to `writeHermesConfig()`
- [ ] Update `runtime/executors/hermes/src/briefing.ts`: add `buildAvailableSkillsIndex()`
      helper; revise closing scope-language string
- [ ] Update `hermes-config.test.ts`: assert gitnexus stanza appears in
      config.yaml when `gitnexusMcpUrl` is set; absent when unset
- [ ] Update `briefing.test.ts`: assert `## Available skills` section present;
      assert revised scope language (allows incremental commits; forbids push/PR/result)
- [ ] Create `phase3_5.test.ts`: assert SOUL.md copied to `~/.hermes/SOUL.md`;
      skills copied to `~/.hermes/skills/`; HERMES.md copied to `<implDir>/HERMES.md`;
      `HERMES.md` line appears in `<implDir>/.git/info/exclude`;
      no-throw when `WORKFLOW_LOCAL_PATH` unset; no-throw when individual
      source files missing
- [ ] Update `workflow/.env.template`: add documented section for Hermes env vars
      (`HERMES_INFERENCE_MODEL`, `HERMES_INFERENCE_PROVIDER`, `HERMES_MAX_TURNS`,
      `RAG_MCP_URL`, `RAG_MCP_TOKEN`, `GITNEXUS_MCP_URL`)
- [ ] Inspect `runtime/orchestrator/templates/docker-compose.yml` for any
      Hermes service block changes needed (expected: none); document in PR
- [ ] Run full Hermes executor test suite — all must pass
- [ ] Run typecheck
- [ ] Open PR

---

## T8 — Validation: real impl + real review, before/after comparison

### Description

Run a real `kind=impl` Hermes task and a real `kind=review` Hermes task after
T7 deploys. Capture before/after quality comparison vs the unadapted Hermes
baseline. Write the handoff document.

This task lives in the management repo because its only output is the handoff
document at `docs/features/hermes-skill-adaptation/handoffs/handoff.md`. The
actual Hermes runs are observation/validation activities, not artifact
production in workflow.

### Required skills
- review-pr

### Subtasks
- [ ] Operator runs the extended `sync-workspace-rules` in the validation
      workspace to materialise `<mgmtRoot>/HERMES.md`
- [ ] Spawn a controlled Hermes session and verify:
      `~/.hermes/SOUL.md` was staged;
      `~/.hermes/skills/` is populated;
      `<implDir>/HERMES.md` is present and listed in `.git/info/exclude`;
      `--ignore-rules` is absent from the spawn args;
      `AGENT_RUNTIME=1` is set
- [ ] Pick one simple `kind=impl` target task (e.g. a docs update or small
      backend change in an indexed repo); route to Hermes; record output
      quality vs. expectations
- [ ] Pick one simple `kind=review` target task; route to Hermes; verify
      GitHub review posted (APPROVE or REQUEST_CHANGES); verify `result.json`
      is valid
- [ ] PR cleanliness check: confirm `HERMES.md` is NOT in the resulting PR's
      file list (this is the regression test for the `.git/info/exclude` trick)
- [ ] Identity injection check: `hermes chat --query "describe your role in
      one sentence"` returns a response referencing "headless executor mode"
      or equivalent SOUL.md language
- [ ] Compose before/after quality comparison: list 3+ concrete improvements
      observed vs. unadapted Hermes baseline (e.g. correct workflow vocabulary,
      MCP usage, scope-boundary respect)
- [ ] Write `docs/features/hermes-skill-adaptation/handoffs/handoff.md` with
      validation evidence and the before/after comparison
- [ ] Open PR with the handoff
