# Tasks — agent-rag-enforce-audit

Feature status: `in_tdd` | Stage: `tasks` | Machine state lives in `tasks/T<n>.yaml`

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T2 | 1 | rag-prefetch + gitnexus-prefetch hook scripts | — |
| T1 | 2 | setupGlobalSettings + claude-settings.json template | T2 |

---

## T2 — rag-prefetch + gitnexus-prefetch hook scripts

### Description

Create the two bash hook scripts that provide RAG and GitNexus context before every `Read` call. These scripts live in `workflow/technical_skills/rag-enforce/` and are copied to `~/.claude/skills/rag-enforce/` by the existing `setupGlobalSkills` mechanism at executor spawn time.

`rag-prefetch` — called for every `Read`. Derives a query from the file basename, calls the RAG HTTP API, and prints ranked results to stdout for Claude to see. Skips non-indexed file types (`.lock`, images, `node_modules/`, `dist/`). Exits 0 always — never blocks the Read.

`gitnexus-prefetch` — called for `Read` on source files (`.ts`, `.tsx`, `.py`, `.go`, `.rs`, `.java`). Queries the GitNexus HTTP API for symbols in the file. Exits 0 always — degrades gracefully when GitNexus is unreachable.

Both scripts must be executable and respect the `MCP_RAG_URL` / `GITNEXUS_MCP_URL` environment variables with sensible localhost defaults.

### Required skills

### Subtasks

- [ ] Create `workflow/technical_skills/rag-enforce/` directory
- [ ] Write `rag-prefetch` script per technical design spec
- [ ] Write `gitnexus-prefetch` script per technical design spec
- [ ] Make both scripts executable (`chmod +x`)
- [ ] Verify skip logic: `.lock`, `.png`, `node_modules/*`, `dist/*` paths exit 0 immediately
- [ ] Verify graceful degradation: curl failure exits 0, Read is not blocked
- [ ] Verify RAG output format: `[score] source_path: content[:200]` per line

---

## T1 — setupGlobalSettings + claude-settings.json template

### Description

Add `setupGlobalSettings` to the executor and create the git-tracked hook configuration template.

`setupGlobalSettings(workflowLocalPath: string)` — new function in `runtime/executors/claude/src/index.ts`, modelled on `setupGlobalSkills`. Copies `workflow/templates/claude-settings.json` to `~/.claude/settings.json` at executor spawn time. Emits `claude_settings_missing` (warning, non-fatal) if the template is absent; emits `claude_settings_written` on success. Called in `main()` immediately after `setupGlobalSkills`.

`workflow/templates/claude-settings.json` — the hook configuration source of truth. Wires `PreToolUse` on `Read` to run both `rag-prefetch` and `gitnexus-prefetch` via the `~/.claude/skills/rag-enforce/` path written by `setupGlobalSkills`.

T2 must be merged before this task so the scripts referenced in the template are present in the repo when this PR lands.

### Required skills

### Subtasks

- [ ] Add `setupGlobalSettings(workflowLocalPath: string): void` to `runtime/executors/claude/src/index.ts`
- [ ] Add `emit('claude_settings_missing', { src })` when template file is absent
- [ ] Add `emit('claude_settings_written', { dest })` on successful copy
- [ ] Call `setupGlobalSettings(workflowLocalPath)` in `main()` after `setupGlobalSkills`
- [ ] Create `workflow/templates/claude-settings.json` with the `PreToolUse` hook config (both scripts)
- [ ] Test: spawn an executor task, verify `~/.claude/settings.json` is written with correct content
- [ ] Test: invoke a `Read` on an indexed file, verify RAG hook output appears in Claude's visible context
- [ ] Test: verify `claude_settings_missing` is emitted (not a crash) when template is absent
