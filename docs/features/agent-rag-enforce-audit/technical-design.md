# Technical Design

## Feature
- Feature ID: `agent-rag-enforce-audit`
- Title: RAG & GitNexus enforce — hook-based enforcement for RAG-first and GitNexus-first lookups

## Current State

| Component | Behaviour today |
|---|---|
| Pre-inject RAG | Orchestrator calls `rag_query` before spawn; result injected into system prompt as `## RAG Context`; `rag_pre_flight` log entry written to task YAML ✓ |
| Mid-task RAG | `mcp__rag-server__rag_query` tool available in executor's tool list; no instruction enforcement ✗ |
| Mid-task GitNexus | `mcp__gitnexus__*` tools available; CLAUDE.md rule present but not enforced ✗ |
| `~/.claude/settings.json` | Not written by executor; no hooks configured ✗ |
| `~/.claude/CLAUDE.md` | Written by `copyWorkspaceClaude` in `runtime/executors/claude/src/index.ts` ✓ |
| `~/.claude/skills/` | Written by `setupGlobalSkills` in `runtime/executors/claude/src/index.ts` ✓ |

## Constraints

1. Hook scripts must degrade gracefully — if RAG/GitNexus is unreachable, the original tool call must proceed unblocked.
2. The source of truth for `~/.claude/settings.json` must be git-tracked.

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

## Files changed

| Repo | File | Change |
|---|---|---|
| `workflow` | `runtime/executors/claude/src/index.ts` | Add `setupGlobalSettings`; call in `main()` |
| `workflow` | `templates/claude-settings.json` | New — hook configuration source of truth |
| `workflow` | `technical_skills/rag-enforce/rag-prefetch` | New — RAG hook script |
| `workflow` | `technical_skills/rag-enforce/gitnexus-prefetch` | New — GitNexus hook script |

## Parallelization

```
T1 — setupGlobalSettings + claude-settings.json template (workflow)   independent
T2 — rag-prefetch + gitnexus-prefetch hook scripts (workflow)         independent

T1 and T2 run in parallel. Both can begin now — no blockers.
```
