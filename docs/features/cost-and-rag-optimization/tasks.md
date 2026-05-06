# Task Breakdown — Cost Accounting & RAG Runtime Optimization

Feature status: [status.yaml](../status.yaml) | Stage: tasks | Machine state lives in `tasks/T<n>.yaml`

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Executor — model capture + cost_usd + RAG audit + .env fix | — |
| T2 | 2 | Orchestrator — persist token_usage + cost_usd to task YAML | T1 |

---

## T1 — Executor — model capture + cost_usd + RAG audit + .env fix

### Description

Extend the Claude executor to extract the model name from stream-json `assistant` events (same events already parsed for token counts), compute `cost_usd` using a hardcoded pricing table, emit `rag_mcp_registered` / `rag_mcp_unavailable` structured log events, parse RAG tool_use/tool_result pairs from stream-json stdout into `RagQueryEvent` records, and uncomment `MCP_RAG_URL` in the template `.env` file.

This task covers all executor-side changes and the ABI schema extension. It is the unblocking task for T2.

Files to change:
- `runtime/executors/claude/src/token-usage.ts` — add `model` extraction + `cost_usd` computation with hardcoded `PRICING` table; fall back to Sonnet rates + emit `pricing_fallback` log event for unknown models
- `runtime/executors/claude/src/rag-audit.ts` — new file; `extractRagQueries(stdout)` correlates tool_use / tool_result pairs by `tool_use_id` and returns `RagQueryEvent[]`
- `runtime/executors/claude/src/index.ts` — emit `rag_mcp_registered` / `rag_mcp_unavailable` after MCP config build; call `extractRagQueries` post-run and emit each as a `rag_query` structured log event; write `cost_usd` and updated `token_usage` (with `model`) to `result.json`
- `runtime/abi/src/schema.ts` — additive: add `model` to `token_usage`; add `cost_usd?: number`
- `runtime/orchestrator/templates/.projects/workspace/.env` — uncomment `MCP_RAG_URL=http://rag-server:8000`

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Extend `token-usage.ts`: capture `model` from `message.model` on `assistant` events; define `PRICING` table for `claude-sonnet-4-6`, `claude-opus-4-7`, `claude-haiku-4-5-20251001`; compute `cost_usd`; fall back to Sonnet rates on unknown model and emit `pricing_fallback` log event; update return type to `{ input, output, model, cost_usd } | undefined`
- [ ] Write `rag-audit.ts`: define `RagQueryEvent` interface (`query`, `chunks_returned`, `top_score`, `scores`); implement `extractRagQueries(stdout)` scanning `assistant` events for `tool_use` with `name == "mcp__rag-server__rag_query"` and `user` events for matching `tool_result`, correlating by `tool_use_id`
- [ ] Update `index.ts`: after building MCP config, emit `rag_mcp_registered` (with `url`) or `rag_mcp_unavailable` (with `reason`); after Claude subprocess exits, call `extractRagQueries` and emit each result as `{ type: "rag_query", at, query, chunks_returned, top_score, scores }` structured log event; write `cost_usd` and `token_usage.model` to `result.json`
- [ ] Extend `runtime/abi/src/schema.ts`: add `model: string` to `token_usage` type; add `cost_usd?: number` field on `ExecutorResult` (additive — no existing fields changed)
- [ ] Uncomment `MCP_RAG_URL=http://rag-server:8000` in `runtime/orchestrator/templates/.projects/workspace/.env`
- [ ] Extend unit tests in `token-usage.ts` test file: assert `model` is extracted correctly; assert `cost_usd` is computed for known models; assert fallback to Sonnet rates + `pricing_fallback` event for unknown models
- [ ] Add unit tests for `rag-audit.ts`: fixture stream-json with tool_use/tool_result pairs → assert correct `RagQueryEvent[]` output; test unmatched tool_use (no result) is dropped gracefully

---

## T2 — Orchestrator — persist token_usage + cost_usd to task YAML

### Description

Update the orchestrator's result-processing path to read `token_usage` (now including `model`) and `cost_usd` from `result.json` and write them into the task YAML log entry for `run_completed`. No pricing logic in the orchestrator — values arrive pre-computed from the executor.

Target log entry shape after this task:
```yaml
- action: run_completed
  by: agent@runtime
  at: 2026-05-06T10:00:00+0700
  note: Run completed.
  token_usage:
    input: 45231
    output: 3812
    model: claude-sonnet-4-6
  cost_usd: 0.19
```

Files to change:
- `runtime/orchestrator/src/` — result-processing path: read `token_usage` + `cost_usd` from result; write them to the task YAML log entry if present (skip gracefully when absent — backward-compatible with executors that don't emit cost data)

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Locate the result-processing path in `runtime/orchestrator/src/` where `run_completed` log entries are written
- [ ] Read `token_usage` and `cost_usd` from the parsed result object (both optional — skip if absent)
- [ ] Write `token_usage` and `cost_usd` into the `run_completed` log entry in the task YAML
- [ ] Add orchestrator integration test: mock `result.json` with `token_usage + cost_usd` → verify task YAML log entry persists both values unchanged; also verify that a result without those fields produces a valid log entry with no extra keys
