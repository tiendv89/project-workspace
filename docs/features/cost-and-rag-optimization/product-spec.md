# Product Specification

## Feature
- Feature ID: `cost-and-rag-optimization`
- Title: Cost Accounting & RAG Runtime Optimization

## Problem

Two gaps exist in the current agent runtime:

**Gap 1 — No cost visibility.**
Each agent run consumes tokens but the platform has no record of how many tokens were used or what that cost in USD. Token counts are captured transiently in `result.json` but never persisted to the task YAML or surfaced in any human-facing output. Operators have no way to see what a feature cost, which tasks were expensive, or whether the platform is spending within acceptable bounds.

**Gap 2 — RAG is only available as a pre-run injection.**
The `rag-context` skill injects RAG-retrieved context into the briefing once, before Claude starts. During a long multi-turn execution, if Claude encounters a question that requires additional context lookups, it cannot query the RAG server again — the MCP is either not wired or not reliably available. Agents fall back to reading files directly, burning tokens on context they already have indexed.

**Gap 3 — RAG usage is not auditable.**
The current executor log emits "received N chunks" but records nothing useful: no query text, no relevance scores, no indication of whether the agent acted on the result or fell back to a direct file read. Operators cannot tell whether RAG is helping or being ignored.

## Goals

1. Token usage (input + output) is persisted per task run in the task YAML log.
2. USD cost is computed per run using the model's per-token pricing and stored alongside token counts.
3. The handoff document includes a cost summary: per-task cost and feature total.
4. An optional `budget_usd` config field lets operators set a spend cap per feature; the orchestrator alerts (and optionally blocks) when the cap is approached or exceeded.
5. The RAG MCP is reliably wired into every executor run so Claude can query RAG at any point during execution — not only from a pre-injected briefing context blob.
6. Agents follow a RAG-first read rule: query RAG before opening a file to look up code, falling back to direct file reads only when RAG returns no relevant results.
7. Each RAG query is logged with query text, relevance scores, chunk count, and whether the agent used the result (hit) or fell back to a file read (miss) — replacing the current "received N chunks" non-signal.

## Non-goals

- Billing integration or invoice generation — cost data is internal reporting only.
- Cross-feature cost aggregation or dashboards — per-feature reporting is sufficient for now.
- Changing the RAG indexing pipeline or corpus — only the runtime wiring is in scope.
- Real-time cost streaming to an external system during a run.

## User Stories

**As an operator**, after a feature completes I want to see how many tokens each task consumed and what it cost in USD — without having to dig through logs.

**As an operator**, I want to set a `budget_usd` on a feature and receive an alert if execution is trending over it, so I can intervene before costs get out of hand.

**As an agent**, during a long implementation run I want to be able to call `mcp__rag-server__rag_query` at any point, not just rely on context that was pre-injected before I started.

**As an agent**, I want a rule that tells me to look up code via RAG before opening files, so I naturally save tokens on every lookup without needing to remember to do it.

**As an operator**, I want RAG query logs that show what was searched, how relevant the results were, and whether the agent used them — not just a count of returned chunks.

## Cost Accounting Design

### Token persistence

When the executor writes the final `result.json`, the orchestrator must also persist `token_usage` into the task YAML as a log entry field:

```yaml
log:
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

### USD cost calculation

Cost is computed from token counts and per-model pricing declared in `workspace.yaml` (or a defaults table). Example:

```yaml
model_pricing:
  claude-sonnet-4-6:
    input_per_mtok: 3.00
    output_per_mtok: 15.00
  claude-opus-4-7:
    input_per_mtok: 15.00
    output_per_mtok: 75.00
```

`cost_usd = (input_tokens / 1_000_000 * input_per_mtok) + (output_tokens / 1_000_000 * output_per_mtok)`

### Budget gate

Optional `budget_usd` in the feature config. If set:
- The orchestrator computes cumulative `cost_usd` across all completed task runs for the feature.
- If cumulative cost exceeds `budget_usd`, the orchestrator emits a `budget_usd_exceeded` event and pauses dispatching new tasks until the operator acknowledges.
- This is a soft gate (alert + pause), not a hard kill of in-flight tasks.

```yaml
feature_reviewer:
  budget_usd: 5.00
```

### Handoff cost summary

The auto-generated handoff document includes a cost summary section:

| Task | Model | Input tokens | Output tokens | Cost USD |
|------|-------|-------------|---------------|----------|
| T1   | claude-sonnet-4-6 | 45,231 | 3,812 | $0.19 |
| T2   | claude-sonnet-4-6 | 71,004 | 5,100 | $0.29 |
| **Total** | | **116,235** | **8,912** | **$0.48** |

## RAG Runtime Wiring

### Current behaviour

The `rag-context` skill pre-queries RAG and injects a context blob into the briefing before `claude -p` is spawned. The RAG MCP (`mcp__rag-server__rag_query`) is conditionally registered via `--mcp-config` only when `MCP_RAG_URL` is present in the executor environment. If `MCP_RAG_URL` is unset, Claude gets no MCP and is limited to the pre-injected blob.

### Required behaviour

1. `MCP_RAG_URL` must be reliably propagated to the executor — the orchestrator must pass it from workspace config if not already in the executor env.
2. The RAG MCP must always be registered when a RAG server is configured for the workspace, regardless of how the executor was invoked.
3. Claude agents must be able to call `mcp__rag-server__rag_query` at any turn during execution, not only during the first turn from pre-injected context.
4. The executor must emit a structured log event (`rag_mcp_registered` / `rag_mcp_unavailable`) so operators can verify RAG wiring without reading raw executor logs.

### RAG-first read rule

Agents must follow this lookup order when searching for code or context:

1. **Query RAG first** via `mcp__rag-server__rag_query`
2. If RAG returns relevant results (score above threshold), use them — do not open the file
3. Fall back to a direct `Read` only when RAG returns no results or low-confidence results

This rule is enforced via a shared workflow rule in `CLAUDE.md` so every agent honours it without the briefing needing to repeat it.

**Exceptions** (direct read is acceptable without a prior RAG query):
- The file path is already known and a targeted line-range read is needed to make an edit
- The file is a config file or lock file unlikely to be in the RAG index
- RAG MCP is unavailable for this run

### RAG audit log

Each RAG query must emit a structured log entry that replaces the current "received N chunks" line:

```json
{
  "type": "rag_query",
  "at": "2026-05-06T10:01:23+0700",
  "query": "how does the executor write result.json",
  "chunks_returned": 3,
  "top_score": 0.87,
  "scores": [0.87, 0.81, 0.74],
  "outcome": "hit"
}
```

`outcome` values:
- `hit` — agent used the RAG result and did not fall back to a file read
- `miss` — RAG returned results but agent opened the file anyway (wasted query)
- `no_results` — RAG returned nothing; direct read was appropriate

This audit data is aggregated per run and included in the handoff document alongside cost data.

### Configuration

```yaml
# workspace.yaml
rag:
  url: http://localhost:8001   # or remote URL in production
  enabled: true
```

When `rag.enabled: true`, the orchestrator injects `MCP_RAG_URL` into every executor submission automatically. No manual env var configuration required per task.

## Dependencies

- Depends on the existing executor ABI (`result.json` with `token_usage: { input, output }`).
- Depends on the orchestrator's `SubProcessAdapter` for env propagation.
- RAG server must be running and reachable at the configured URL.

## Success Metrics

- Every completed task run has `token_usage` and `cost_usd` in its task YAML log entry.
- Handoff documents include a populated cost summary table.
- Agents in long runs successfully call `mcp__rag-server__rag_query` mid-execution (verified via executor logs showing `rag_mcp_registered` and mid-run `rag_query` tool calls).
- Zero tasks complete with `MCP_RAG_URL` unset when `rag.enabled: true` in workspace config.

## Open Questions

1. Should model be captured from Claude's `stream-json` output (each assistant event includes a `model` field) or passed as an executor env var? Capturing from stdout is more reliable but requires a small parser change.
2. Should `budget_usd` pause only new dispatches or also attempt to cancel in-flight tasks?
