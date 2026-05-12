# Technical Design

## Feature
- Feature ID: `agent-rag-enforce-audit`
- Title: RAG & GitNexus enforce + audit — hook-based enforcement and tamper-proof mid-task query logging

## Current State

| Component | Behaviour today |
|---|---|
| Pre-inject RAG | Orchestrator calls `rag_query` before spawn; result injected into system prompt as `## RAG Context`; `rag_pre_flight` log entry written to task YAML ✓ |
| Mid-task RAG | `mcp__rag-server__rag_query` tool available in executor's tool list; no instruction enforcement; no audit trail ✗ |
| Mid-task GitNexus | `mcp__gitnexus__*` tools available; CLAUDE.md rule present but not enforced; no audit trail ✗ |
| `~/.claude/settings.json` | Not written by executor; no hooks configured ✗ |
| `~/.claude/CLAUDE.md` | Written by `copyWorkspaceClaude` in `runtime/executors/claude/src/index.ts` ✓ |
| `~/.claude/skills/` | Written by `setupGlobalSkills` in `runtime/executors/claude/src/index.ts` ✓ |

## Constraints

1. Hook scripts must degrade gracefully — if RAG/GitNexus is unreachable, the original tool call must proceed unblocked.
2. The source of truth for `~/.claude/settings.json` must be git-tracked.
3. Server-side query logs must not require schema changes to the existing Qdrant collection.
4. Audit summary must be written by the orchestrator, not the executor — the executor must not make management-repo mutations.

## Design

### Change 1 — `setupGlobalSettings` in executor

**File:** `runtime/executors/claude/src/index.ts`

New function alongside `copyWorkspaceClaude`:

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

**Location:** `workflow/technical_skills/rag-enforce/` (git-tracked; copied to `~/.claude/skills/rag-enforce/` by `setupGlobalSkills`)

Two scripts:

#### `rag-prefetch`

Called by the `PreToolUse` hook on every `Read` call. Receives the file path via env var `CLAUDE_TOOL_INPUT_FILE_PATH`.

```bash
#!/usr/bin/env bash
# Queries RAG for the file being read. Prints results to stdout for Claude to see.
# Exits 0 always — never blocks the Read.
FILE="$CLAUDE_TOOL_INPUT_FILE_PATH"
WS="${MCP_RAG_WORKSPACE_ID:-workspace}"
URL="${MCP_RAG_URL:-http://localhost:8001}"

# Skip non-indexed file types
case "$FILE" in
  *.lock|*.png|*.jpg|*.gif|*.ico|node_modules/*|dist/*) exit 0 ;;
esac

# Derive query from file path (basename without extension)
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

Called by the `PreToolUse` hook on `Read` for source files. Queries GitNexus for the file's symbols.

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

Git-tracked source of truth for hook configuration:

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

### Change 4 — Server-side query logging (rag-service)

**File:** `rag_service/services/rag_server/server.py` (or equivalent FastMCP entry point)

Add a middleware / decorator on the `rag_query` handler that appends a line to a per-workspace JSONL log:

```
~/.claude/rag-audit/<workspace_id>.jsonl
```

Each line:

```json
{
  "ts": "2026-05-13T01:23:45+07:00",
  "workspace_id": "workspace",
  "query": "runOneCycle decomposition",
  "source_types": ["technical_design"],
  "top_k": 5,
  "result_count": 5,
  "top_score": 0.778,
  "duration_ms": 42
}
```

The log path is accessible to the orchestrator after the executor exits (shared filesystem in local-subprocess and local-docker profiles).

### Change 5 — `rag_mid_task_summary` orchestrator step

After the executor exits and before `result.json` is processed, the orchestrator reads the server-side query log for the task's execution window (entries between `started_at` and `finished_at` timestamps).

It writes a `rag_mid_task_summary` log entry to the task YAML:

```yaml
- action: rag_mid_task_summary
  by: orchestrator
  at: <timestamp>
  rag_calls: 7
  gitnexus_calls: 3
  avg_rag_score: 0.74
  zero_result_queries: 1
  note: "7 mid-task RAG calls, 3 GitNexus calls. 1 query returned no results."
```

## Files changed

| Repo | File | Change |
|---|---|---|
| `workflow` | `runtime/executors/claude/src/index.ts` | Add `setupGlobalSettings`; call in `main()` |
| `workflow` | `templates/claude-settings.json` | New — hook configuration source of truth |
| `workflow` | `technical_skills/rag-enforce/rag-prefetch` | New — RAG hook script |
| `workflow` | `technical_skills/rag-enforce/gitnexus-prefetch` | New — GitNexus hook script |
| `workflow` | `runtime/orchestrator/src/main.ts` | Add `rag_mid_task_summary` step after executor exit |
| `rag-service` | `services/rag_server/server.py` | Add query logging middleware |

## Parallelization

```
T1 — setupGlobalSettings + claude-settings.json template (workflow)   independent
T2 — rag-prefetch + gitnexus-prefetch hook scripts (workflow)         independent
T3 — rag_mid_task_summary orchestrator step (workflow)                independent
T4 — RAG server query logging (rag-service)                           independent
```

All four tasks are independent and can run in parallel.
T3 depends on T4 having a log to read, but can be developed against a stub log for testing.
