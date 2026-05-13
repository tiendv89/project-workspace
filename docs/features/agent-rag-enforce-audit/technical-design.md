# Technical Design

## Feature
- Feature ID: `agent-rag-enforce-audit`
- Title: RAG & GitNexus enforce — hook-based enforcement for RAG-first and GitNexus-first lookups

---

## 1. Current State

| Component | Behaviour today |
|---|---|
| Pre-inject RAG | Orchestrator calls `rag_query` before spawn; result injected into system prompt as `## RAG Context`; `rag_pre_flight` log entry written to task YAML ✓ |
| Mid-task RAG | `mcp__rag-server__rag_query` tool available in executor's tool list; no enforcement ✗ |
| Mid-task GitNexus | `mcp__gitnexus__*` tools available; CLAUDE.md rule present but not enforced ✗ |
| `~/.claude/settings.json` | Not written by executor; no hooks configured ✗ |
| `~/.claude/CLAUDE.md` | Written by `copyWorkspaceClaude` in `runtime/executors/claude/src/index.ts` ✓ |
| `~/.claude/skills/` | Written by `setupGlobalSkills` in `runtime/executors/claude/src/index.ts` ✓ |

The executor already has a pattern for writing context files at spawn time (`copyWorkspaceClaude`, `setupGlobalSkills`). There is no equivalent for `~/.claude/settings.json`.

---

## 2. Problem Framing

**What needs to change:**
- A `setupGlobalSettings` function must be added to the executor so `~/.claude/settings.json` is written at spawn time from a git-tracked template.
- The template must configure `PreToolUse` hooks that run RAG and GitNexus queries before every `Read` call.
- Hook scripts must live in `workflow/technical_skills/rag-enforce/` so `setupGlobalSkills` copies them to `~/.claude/skills/rag-enforce/` and they are available at the hook command path.

**What must remain stable:**
- `copyWorkspaceClaude` and `setupGlobalSkills` — no changes to existing functions.
- The pre-inject `rag_pre_flight` mechanism — unchanged.
- The executor's tool list and MCP server wiring — hooks are additive.

**Assumptions fixed:**
- Claude Code supports `PreToolUse` hooks with `matcher: Read` via `~/.claude/settings.json`.
- Hook commands that exit 0 never block the tool call — they only augment context.
- `WORKFLOW_LOCAL_PATH` is set in the executor environment (it already is; used by `setupGlobalSkills`).

---

## 3. Options Considered

### Option A — Text rule in CLAUDE.md (current state)
The existing approach: CLAUDE.md instructs agents to query RAG before reading files.

**Pros:** Zero implementation cost.
**Cons:** Does not work. Model training bias toward `Read` overrides text instructions. Agents skip the rule consistently. This is the problem being solved.
**Verdict:** Rejected.

### Option B — PreToolUse hook (chosen)
Install a `PreToolUse` hook in `~/.claude/settings.json` matching `Read`. The hook script runs a RAG query and prints results to stdout before the Read executes. Claude sees the RAG output as additional context before processing the file content.

**Pros:** Mechanical enforcement — cannot be skipped by agent behavior. Degrades gracefully (hook exits 0 if RAG/GitNexus unavailable). Follows the existing `setupGlobalSkills` deployment pattern. No changes to orchestrator or MCP server.
**Cons:** Hook output adds tokens on every Read, including Reads where RAG would return nothing useful (e.g. config files). Mitigated by skipping non-indexed file types in the script.
**Verdict:** Chosen.

### Option C — Wrapper skill replacing Read
Publish a custom MCP tool that wraps Read: it always queries RAG first, then returns file content. Agents use the wrapper instead of the native Read.

**Pros:** Complete control over the lookup sequence.
**Cons:** Requires agents to use the custom tool instead of the built-in Read — not enforceable without removing Read from the tool list, which would break many workflows. Significantly more invasive.
**Verdict:** Rejected.

---

## 4. Chosen Design

**Hook-based enforcement via `PreToolUse` on `Read`.** A git-tracked `claude-settings.json` template is deployed to `~/.claude/settings.json` at executor spawn time by a new `setupGlobalSettings` function. Two hook scripts (`rag-prefetch`, `gitnexus-prefetch`) run before every Read, query their respective services, and print context to stdout. The agent sees the RAG/GitNexus output before processing the file.

**Affected repo:** `workflow` only. Three changes, all additive.

**Compatibility:** Existing executor runs without the template degrade safely — `setupGlobalSettings` emits `claude_settings_missing` and returns without error. Runs with the template but without `MCP_RAG_URL` set degrade safely — hook scripts exit 0 on curl failure.

**Release:** No migration. Deployed as a normal `workflow` repo PR. Takes effect on the next executor spawn after the new `workflow` image/code is in use.

### Change 1 — `setupGlobalSettings` in executor

**File:** `runtime/executors/claude/src/index.ts`

```typescript
function setupGlobalSettings(workflowLocalPath: string): void {
  const src = path.join(workflowLocalPath, 'templates', 'claude-settings.json');
  const dest = path.join(os.homedir(), '.claude', 'settings.json');
  if (!fs.existsSync(src)) {
    emit('claude_settings_missing', { src });
    return;
  }
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
  emit('claude_settings_written', { dest });
}
```

Called in `main()` immediately after `setupGlobalSkills`:

```typescript
copyWorkspaceClaude(workspaceRoot);
setupGlobalSkills(workspaceRoot, workflowLocalPath);
setupGlobalSettings(workflowLocalPath);  // ← new
```

### Change 2 — Hook scripts

**Location:** `workflow/technical_skills/rag-enforce/`

Copied to `~/.claude/skills/rag-enforce/` by the existing `setupGlobalSkills` mechanism.

#### `rag-prefetch`

```bash
#!/usr/bin/env bash
# Queries RAG for the file being read. Prints results to stdout for Claude to see.
# Exits 0 always — never blocks the Read.
FILE="$CLAUDE_TOOL_INPUT_FILE_PATH"
WS="${MCP_RAG_WORKSPACE_ID:-workspace}"
URL="${MCP_RAG_URL:-http://localhost:8001}"

case "$FILE" in
  *.lock|*.png|*.jpg|*.gif|*.ico|node_modules/*|dist/*) exit 0 ;;
esac

QUERY=$(basename "$FILE" | sed 's/\.[^.]*$//')

RESULT=$(curl -sf --max-time 3 "$URL/rag_query" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"$QUERY\",\"workspace_id\":\"$WS\",\"top_k\":3}" 2>/dev/null)

if [ -n "$RESULT" ]; then
  echo "## RAG context for $FILE"
  echo "$RESULT" | jq -r '.result[] | "[\(.score | . * 100 | round / 100)] \(.source_path): \(.content[:200])"' 2>/dev/null
fi
exit 0
```

#### `gitnexus-prefetch`

```bash
#!/usr/bin/env bash
FILE="$CLAUDE_TOOL_INPUT_FILE_PATH"
URL="${GITNEXUS_MCP_URL:-http://localhost:18001}"

case "$FILE" in
  *.ts|*.tsx|*.py|*.go|*.rs|*.java) ;;
  *) exit 0 ;;
esac

QUERY=$(basename "$FILE" | sed 's/\.[^.]*$//')
RESULT=$(curl -sf --max-time 3 "$URL/query" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"$QUERY\",\"limit\":3}" 2>/dev/null)

if [ -n "$RESULT" ]; then
  echo "## GitNexus context for $FILE"
  echo "$RESULT" | jq -r '.process_symbols[]? | "\(.name) (\(.filePath):\(.startLine))"' 2>/dev/null
fi
exit 0
```

### Change 3 — `workflow/templates/claude-settings.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/skills/rag-enforce/rag-prefetch"
          },
          {
            "type": "command",
            "command": "~/.claude/skills/rag-enforce/gitnexus-prefetch"
          }
        ]
      }
    ]
  }
}
```

---

## 5. Dependency Analysis

| Dependency | Type | Status |
|---|---|---|
| Claude Code `PreToolUse` hook with `matcher: Read` | External — Claude Code feature | Available in current Claude Code version ✓ |
| `setupGlobalSkills` copies `technical_skills/rag-enforce/` to `~/.claude/skills/rag-enforce/` | Internal — existing executor convention | Already works for other skills ✓ |
| `WORKFLOW_LOCAL_PATH` env var set in executor | Internal — executor environment | Already set; used by `setupGlobalSkills` ✓ |
| `MCP_RAG_URL` set in executor environment | Internal — graceful degradation | Optional; hook exits 0 if unset ✓ |
| `GITNEXUS_MCP_URL` set in executor environment | Internal — graceful degradation | Optional; hook exits 0 if unset ✓ |

No unresolved dependencies. All external dependencies are already satisfied by the current runtime.

**Deployment ordering note:** The hook scripts (T2) must be present in `workflow/technical_skills/rag-enforce/` before the settings template (T1) is deployed — otherwise the settings file references scripts that don't exist yet and hooks would fail silently. Since both changes land in the same `workflow` repo PR, this is naturally satisfied.

---

## 6. Parallelization / Blocking Analysis

```
T1 — setupGlobalSettings function + claude-settings.json template (workflow)
  └── Can begin now — no blockers

T2 — rag-prefetch + gitnexus-prefetch hook scripts (workflow)
  └── Can begin now — no blockers

T1 and T2 run in parallel.
Both are in the workflow repo. They should be merged in the same PR or T2 before T1
(scripts must exist before the settings template references them at deploy time).
```

---

## 7. Repository Impact

| Repo | Impact | Files |
|---|---|---|
| `workflow` | **Modified** — new function in executor, new template file, new hook scripts | `runtime/executors/claude/src/index.ts`, `templates/claude-settings.json`, `technical_skills/rag-enforce/rag-prefetch`, `technical_skills/rag-enforce/gitnexus-prefetch` |

No other repos are affected. `rag-service` and `git-nexus` are unchanged — hooks call their HTTP APIs directly via curl, not through any new server-side code.

---

## 8. Validation and Release Impact

**Testing:**
- Spawn an executor task and verify `~/.claude/settings.json` is written with the correct hook configuration.
- Invoke a `Read` on an indexed file and verify the RAG prefetch output appears in Claude's visible context.
- Verify graceful degradation: with `MCP_RAG_URL` unset, the hook exits 0 and the Read proceeds without error.
- Verify skip logic: `Read` on a `.lock` or `node_modules/` path does not trigger a RAG query.

**Migration / config impact:** None. Existing executor environments without the template file emit a warning log and continue — no breaking change.

**Backward compatibility:** Safe. `setupGlobalSettings` is a no-op when the template file is absent.

**Rollout:** Standard `workflow` PR. Takes effect on next executor spawn. No restart of RAG or GitNexus services required.
