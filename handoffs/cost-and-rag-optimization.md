# Handoff — Cost Accounting & RAG Runtime Optimization

**Feature:** `cost-and-rag-optimization`
**Handoff date:** 2026-05-07
**Implementation repo:** `tiendv89/agent-workflow`

---

## What was built

### T1 — Executor: model capture + cost_usd + RAG audit (PR #79)

**`runtime/executors/claude/src/token-usage.ts`**
- Extracts `model` from `message.model` on `assistant` stream-json events
- Hardcoded `PRICING` table for `claude-sonnet-4-6`, `claude-opus-4-7`, `claude-haiku-4-5-20251001`
- Computes `cost_usd` from input/output token counts × pricing rates
- Falls back to Sonnet rates for unknown models and emits a `pricing_fallback` structured log event

**`runtime/executors/claude/src/rag-audit.ts`** _(new file)_
- Defines `RagQueryEvent` interface: `{ query, chunks_returned, top_score, scores }`
- `extractRagQueries(stdout)` scans stream-json stdout for `tool_use` events with `name == "mcp__rag-server__rag_query"` and correlates matching `tool_result` events by `tool_use_id`
- Unmatched tool_use (no result) is dropped gracefully

**`runtime/executors/claude/src/index.ts`**
- Emits `rag_mcp_registered` (with `url`) or `rag_mcp_unavailable` (with `reason`) after MCP config build
- After Claude subprocess exits, calls `extractRagQueries` and emits each result as a `rag_query` structured log event
- Writes `cost_usd` and `token_usage.model` to `result.json`

**`runtime/abi/src/schema.ts`**
- `token_usage` extended with `model: string`
- `ExecutorResult` extended with `cost_usd?: number`
- Both additions are additive — backward-compatible with orchestrators that don't read them

**`runtime/orchestrator/templates/.projects/workspace/.env`**
- `MCP_RAG_URL=http://rag-server:8000` uncommented — new workspace setups now wire up the RAG server automatically

---

### T2 — Orchestrator: persist token_usage + cost_usd to task YAML (PR #81)

**`runtime/orchestrator/src/side-effects/dispatch.ts`**
- `in_review` log action replaced with `run_completed` for successful executor runs
- `token_usage` and `cost_usd` spread onto `run_completed` and `blocked` log entries when present in `ExecutorResult`; omitted when absent (backward-compatible)
- Log entry shape:
  ```yaml
  - action: run_completed
    by: agent@runtime
    at: 2026-05-07T...
    note: Implementation PR: https://github.com/...
    token_usage:
      input: 45231
      output: 3812
      model: claude-sonnet-4-6
    cost_usd: 0.19
  ```

**`runtime/orchestrator/tests/seam-executor-dispatch.test.ts`**
- 9 seam tests covering: `in_review` with/without `pr_url`, `blocked` with `pr_url`, `failed` terminal statuses, and cost data persistence for both `run_completed` and `blocked` log entries

**`runtime/orchestrator/tests/reap-loop.test.ts`**
- E2E assertion updated to expect `run_completed` action (was `in_review`)

---

### Bonus fix — `appendLogEntry` checkout ordering bug (PR #82)

Discovered and fixed during this session: `appendLogEntry` was writing the mutated YAML to disk before calling `git checkout -B origin/<branch>`, which resets the working tree and silently discarded the write. Log entries were never committed. Fixed by restructuring to match the correct pattern in `mutate-task-yaml.ts` (checkout first, then read/mutate/write/commit). 7 new tests added including ordering assertions.

---

## Operational notes

- **Pricing table is hardcoded** in `runtime/executors/claude/src/token-usage.ts`. When new Claude models ship, add their rates to the `PRICING` constant and redeploy the executor container.
- **MCP_RAG_URL is now enabled** in the `.env` template. Existing deployments using the old template are unaffected; new workspace initialisations will connect to the RAG stack automatically.
- **No database migrations** — all new fields (`token_usage.model`, `cost_usd`) land only in task YAML log entries. No schema changes to external systems.
- **Backward-compatible** — orchestrators running against older executors that don't emit `cost_usd` will silently omit those fields from log entries.

---

## PRs shipped

| PR | Repo | Title | Status |
|---|---|---|---|
| [#79](https://github.com/tiendv89/agent-workflow/pull/79) | agent-workflow | feat(cost-and-rag-optimization/T1): executor model capture + cost_usd + RAG audit | merged |
| [#81](https://github.com/tiendv89/agent-workflow/pull/81) | agent-workflow | feat(cost-and-rag-optimization/T2): persist token_usage + cost_usd to task log | merged |
| [#82](https://github.com/tiendv89/agent-workflow/pull/82) | agent-workflow | fix(orchestrator): correct checkout ordering in appendLogEntry | open |
