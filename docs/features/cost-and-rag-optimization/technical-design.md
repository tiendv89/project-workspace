# Technical Design

## Feature
- Feature ID: `cost-and-rag-optimization`
- Title: Cost Accounting & RAG Runtime Optimization

---

## 1. Current State

### Executor (`workflow/runtime/executors/claude/src/`)

- `token-usage.ts` — already parses per-turn `assistant` events from `stream-json` stdout and sums `input_tokens` + `output_tokens`. Result is `{ input, output } | undefined`.
- `index.ts` — attaches `token_usage` to `result.json` before writing it. Checks `BUDGET_TOKENS` env var **after the run exits** — if total tokens exceeded the limit, writes `blocked_reason: "budget_exceeded"`. This is post-hoc detection, not enforcement: Claude has already consumed the tokens before the check runs. There is no mechanism to interrupt a `claude -p` subprocess mid-turn based on token count without killing the process (which would leave no `result.json`).
- The `assistant` event in stream-json also carries a `model` field (e.g. `"claude-sonnet-4-6"`) — **this is currently ignored and discarded**.
- RAG MCP is conditionally wired via `--mcp-config` only when `MCP_RAG_URL` is present in the executor's own env. The executor already has `WORKSPACE_ROOT` in env but does not currently read `workspace.yaml` to self-configure the RAG URL — it relies entirely on the caller having set `MCP_RAG_URL` manually.
- The executor emits a `budget_audit` structured log event but **no** `rag_mcp_registered` / `rag_mcp_unavailable` events.
- RAG tool_use and tool_result events appear in the stream-json stdout but are **not currently parsed** — neither query text, relevance scores, nor chunk count are captured anywhere.

### ABI (`workflow/runtime/abi/src/schema.ts`)

- `ExecutorResult` schema: `terminal_status`, optional `token_usage: { input, output }`, `blocked_reason`, `blocked_suggestion`, `pr_url`, `handover_path`.
- No `model`, `cost_usd`, or RAG audit fields in the ABI schema.

### Orchestrator (`workflow/runtime/orchestrator/src/`)

- `SubProcessAdapter.submit()` takes `budgetTokens` (optional) and passes it as `BUDGET_TOKENS` to the executor. No `budget_usd` equivalent exists.
- When the broker delivers a completed result, the orchestrator processes it and updates the task YAML. It reads `token_usage` from the result but **does not persist it** to the task YAML log entry.
- No cost calculation logic exists anywhere in the orchestrator.

### `workspace.yaml`

- Has `model_policy` (per-phase model allowlists) but **no `model_pricing`** table.
- Has **no `rag` config section** — `MCP_RAG_URL` must be manually set as an env var per deployment.

### Task YAML log entries

Current shape written by orchestrator on result processing:
```yaml
log:
  - action: run_completed
    by: agent@runtime
    at: 2026-05-06T10:00:00+0700
    note: Run completed.
    # token_usage is NOT written here today
```

---

## 2. Problem Framing

### Must change
1. `token_usage` and `model` must survive past `result.json` and land in the task YAML log.
2. USD cost must be computed and stored per run.
3. `MCP_RAG_URL` must be auto-injected when `rag.enabled: true` in `workspace.yaml` — not rely on manual env configuration.
4. The executor must emit `rag_mcp_registered` / `rag_mcp_unavailable` so operators can audit wiring.
5. RAG query events from stream-json stdout must be parsed and emitted as structured log events (query text, scores, chunk count).
6. Model name must be extracted from stream-json and carried through to `result.json` and task YAML.

### Must remain stable
- The executor ABI contract (`result.json` schema, `RESULT_PATH`, `BRIEFING_PATH`) — additive fields only.
- The task YAML log schema — new fields are added to log entries; existing fields and entry shapes are unchanged.
- The git-based claim protocol and task status state machine.
- The `workspace_id` partition requirement on all RAG queries.

### Fixed assumptions
- Model name appears in `stream-json` `assistant` events under `message.model` — same events already parsed for token counts.
- RAG tool_use events appear in stream-json as `type: "assistant"` with `content[].type == "tool_use"` and `name == "mcp__rag-server__rag_query"`.
- RAG tool_result events follow as `type: "user"` with `content[].type == "tool_result"` carrying the chunks (each with a `score` field from the rag-service response).
- Budget enforcement (blocking dispatch based on cumulative cost) is out of scope for this feature — accounting correctness comes first.

---

## 3. Options Considered

### Option A — Persist cost in executor (write directly to task YAML from executor)

**What it is:** The executor, after writing `result.json`, also directly updates the task YAML log entry with `token_usage`, `model`, and `cost_usd`.

**Pros:** Simple — cost is written in the same process that has token data.

**Cons:** Violates the ABI boundary. The executor is not supposed to own workflow-state writes — the orchestrator owns those (per `agent-runtime-split` design). The executor already has `TASK_ID` and `WORKSPACE_ROOT` in its env and does write to task YAML during execution (claim, status updates) via the `start-implementation` flow — but the result-processing path is explicitly owned by the orchestrator. Mixing this breaks the ownership contract.

**Verdict:** Rejected.

---

### Option B — Persist cost in orchestrator result-processing path (chosen)

**What it is:** After the broker delivers a completed result, the orchestrator's result-processing step reads `token_usage` + `model` from `result.json`, computes `cost_usd` using `model_pricing` from `workspace.yaml`, and writes all three into the task YAML log entry.

**Pros:** Respects the orchestrator/executor ownership split. Cost calculation lives in one place. `workspace.yaml` is already read by the orchestrator at startup. Additive — no ABI schema breakage.

**Cons:** Requires two `workspace.yaml` additions (`model_pricing`, `rag`). If `model` is missing from `result.json` (executor didn't capture it), cost falls back to a default pricing tier.

**Verdict:** Chosen.

---

### Option C — Store pricing outside workspace.yaml (e.g. hardcoded defaults table in orchestrator)

**What it is:** Hardcode Anthropic's public pricing table in the orchestrator; no `workspace.yaml` change needed.

**Pros:** No config ceremony.

**Cons:** Pricing changes require a code deploy. Doesn't support custom model endpoints with different pricing. Operators can't override pricing without a code change.

**Verdict:** Rejected. `workspace.yaml` is the right place for operator-configured pricing. A hardcoded defaults table is acceptable as a fallback when a model is not in `model_pricing`, but should not be the primary mechanism.

---

### Option D — RAG audit via rag-service middleware (server-side logging)

**What it is:** The rag-service logs every query it receives — query text, scores, requester identity.

**Pros:** Zero executor changes needed for audit data.

**Cons:** Audit data lives in the rag-service, not co-located with the task run log. Correlating a rag-service query log entry with a specific task run requires a trace ID that doesn't currently exist. Doesn't help with "did the agent use the result?" (hit/miss).

**Verdict:** Rejected for this feature. Server-side logging is complementary and can be added later. The executor-side approach keeps audit data co-located with task run data.

---

## 4. Chosen Design

### Track 1 — Cost accounting

#### 4.1 workspace.yaml additions

Add two new sections:

```yaml
model_pricing:
  claude-sonnet-4-6:
    input_per_mtok: 3.00
    output_per_mtok: 15.00
  claude-opus-4-7:
    input_per_mtok: 15.00
    output_per_mtok: 75.00
  claude-haiku-4-5-20251001:
    input_per_mtok: 0.80
    output_per_mtok: 4.00

rag:
  url: http://localhost:8001
  enabled: true
```

`model_pricing` uses MTok (million token) pricing matching Anthropic's public API rates. The orchestrator applies a hardcoded fallback (`claude-sonnet-4-6` rates) if a model is not in the table.

#### 4.2 Executor — model capture

Extend `token-usage.ts` to also extract `model` from `assistant` events:

```ts
// assistant event shape:
// { type: "assistant", message: { model: "claude-sonnet-4-6", usage: { input_tokens, output_tokens } } }
export function extractTokenUsage(stdout: string): 
  { input: number; output: number; model?: string } | undefined
```

The last non-null `model` value seen across all turns is used (model doesn't change mid-run). Returned in the result object alongside `{ input, output }`.

Extend `ExecutorResult` ABI (additive):
```ts
token_usage?: { input: number; output: number; model?: string }
```

#### 4.3 Executor — `rag_mcp_registered` / `rag_mcp_unavailable` events

In `index.ts`, after building the MCP config, emit one of:
```json
{ "type": "rag_mcp_registered", "url": "http://localhost:8001" }
{ "type": "rag_mcp_unavailable", "reason": "MCP_RAG_URL not set" }
```

#### 4.4 Executor — self-configure RAG from `workspace.yaml` (enables mid-execution queries)

When `--mcp-config` is passed to `claude -p`, the registered MCP tools are available **for the entire session** — not just the first turn. This is how mid-execution RAG queries work: Claude can call `mcp__rag-server__rag_query` at any turn, not only from context that was pre-injected into the briefing before the session started. The pre-run `rag-context` skill injection and mid-run MCP queries are complementary, not alternatives.

The current gap is that `--mcp-config` is only added when `MCP_RAG_URL` is in the executor's env. If it is unset, Claude gets no RAG MCP at all and is limited to the briefing blob for the full session.

The fix is to have the executor resolve `mcpRagUrl` from `workspace.yaml` directly, falling back to `MCP_RAG_URL` env var for backward compatibility:

```ts
// In index.ts, before building mcpConfig:
let mcpRagUrl = process.env.MCP_RAG_URL;
if (!mcpRagUrl && workspaceRoot) {
  const wsConfig = readWorkspaceConfig(workspaceRoot);  // already parsed for other uses
  if (wsConfig?.rag?.enabled && wsConfig?.rag?.url) {
    mcpRagUrl = wsConfig.rag.url;
  }
}
```

This preserves the `local-subprocess` contract: the orchestrator passes `WORKSPACE_ROOT` (which it already does), and the executor self-configures everything else. The orchestrator has no knowledge of MCP internals.

#### 4.5 Orchestrator — cost calculation + task YAML persistence

In the result-processing path, after receiving a completed result from the broker:

```ts
function computeCost(tokenUsage: { input: number; output: number; model?: string }, pricing: ModelPricing): number {
  const rates = pricing[tokenUsage.model ?? 'claude-sonnet-4-6'] ?? pricing['claude-sonnet-4-6'];
  return (tokenUsage.input / 1_000_000 * rates.input_per_mtok)
       + (tokenUsage.output / 1_000_000 * rates.output_per_mtok);
}
```

Write to task YAML log entry:
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

---

### Track 2 — RAG audit log

#### 4.7 Executor — RAG query extraction from stream-json

Add `rag-audit.ts` alongside `token-usage.ts`:

```ts
export interface RagQueryEvent {
  query: string;
  chunks_returned: number;
  top_score: number;
  scores: number[];
}

export function extractRagQueries(stdout: string): RagQueryEvent[]
```

Parse strategy:
1. Scan `assistant` events for `content[]` blocks of type `tool_use` with `name == "mcp__rag-server__rag_query"` → capture `input.query` and `tool_use_id`.
2. Scan `user` events for `content[]` blocks of type `tool_result` matching each `tool_use_id` → extract chunk scores from the result payload.
3. Correlate by `tool_use_id`. Return one `RagQueryEvent` per matched pair.

Emit each as a structured log event after the Claude run completes:
```json
{
  "type": "rag_query",
  "at": "2026-05-06T10:01:23+0700",
  "query": "how does the executor write result.json",
  "chunks_returned": 3,
  "top_score": 0.87,
  "scores": [0.87, 0.81, 0.74]
}
```

**Note on `outcome` (hit/miss):** The hit/miss determination requires inferring whether the agent acted on RAG results (e.g., did not subsequently `Read` the same file). This is ambiguous from the stream alone. `outcome` is deferred to a follow-on feature — for now, emit query + scores only. This is already a major improvement over "received N chunks".

---

## 5. Dependency Analysis

### Internal dependencies

| Dependency | On what | Unblocked by |
|---|---|---|
| T2 (executor self-config + audit) | T1 — needs `rag` section in `workspace.yaml` to read at runtime | Human completes T1 |
| T3 (cost calculation) | T1 — needs `model_pricing` in `workspace.yaml` | Human completes T1 |
| T3 (cost calculation) | T2 — needs `model` field in `result.json` | T2 ships to `workflow` |

### External dependencies

None. All changes are within the `workflow` and `management-repo` repos. No third-party API or tooling changes.

### Unresolved decisions

None — the one open question from the product spec is resolved:
1. **Model capture**: from `stream-json` stdout (same events as token extraction) — not via env var. More reliable.

Budget enforcement (`budget_usd` dispatch gate) is deferred to a follow-on feature. Accounting correctness ships first.

---

## 6. Parallelization / Blocking Analysis

```
T1: workspace.yaml — add model_pricing + rag config     [management-repo]
  └── Can begin now — no blockers
  └── Human task; short config edit

  T2: Executor — model capture + self-configure RAG from workspace.yaml + rag_mcp events + RAG audit     [workflow]
      └── BLOCKED on T1 (executor reads rag.url from workspace.yaml at runtime — section must exist)

      T3: Orchestrator — cost calculation + persist token_usage/cost_usd to task YAML     [workflow]
            └── BLOCKED on T1 (model_pricing table must exist in workspace.yaml)
            └── BLOCKED on T2 (model field must be in result.json before orchestrator can persist it)
```

T1 is the only wave-1 task. T2 unblocks on T1. T3 unblocks on T1 + T2. Maximum depth is 3 steps (T1 → T2 → T3). Note: T2's dep on T1 is a runtime dep (executor reads workspace.yaml when it runs), not a compile-time dep — T2 can be coded and merged before T1 ships, but must not be tested end-to-end until T1 is in place.

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `management-repo` | `workspace.yaml` — add `model_pricing` and `rag` sections | Config-driven pricing and RAG wiring |
| `workflow` | `runtime/executors/claude/src/token-usage.ts` — add model extraction | Capture model from stream-json |
| `workflow` | `runtime/executors/claude/src/rag-audit.ts` — new file | RAG query event extraction |
| `workflow` | `runtime/executors/claude/src/index.ts` — self-configure RAG from workspace.yaml; emit rag_mcp events; call extractRagQueries | Self-contained RAG wiring + audit |
| `workflow` | `runtime/abi/src/types.ts` — add `model?` to token_usage | ABI additive extension |
| `workflow` | `runtime/orchestrator/src/` — result-processing path only | Cost persistence into task YAML log |

No changes to `rag-service`, `digital-factory-ui`, or `workflow-backend`.

---

## 8. Validation and Release Impact

### Testing expectations

- `token-usage.ts` already has unit tests. Extend them to assert `model` is extracted correctly.
- Add unit tests for `rag-audit.ts`: fixture stream-json with tool_use/tool_result pairs → verify correct `RagQueryEvent` output.
- Orchestrator integration test: mock result with `token_usage + model` → verify task YAML log entry contains `cost_usd` at correct value.

### Migration / config impact

- `workspace.yaml` additions are additive. Orchestrators reading a `workspace.yaml` without `model_pricing` or `rag` fall back gracefully (no cost calculation, no auto-injection).
- `ExecutorResult` ABI extension is additive (`model?` is optional) — existing executors without model capture still produce valid results.

### Backward compatibility

- All changes are additive. No existing fields are removed or renamed.
- `BUDGET_TOKENS` post-hoc detection continues to work unchanged. Budget enforcement is deferred — this feature only adds accurate accounting (tokens + cost persisted to task YAML). A follow-on feature will add the dispatch gate once the accounting data is trusted.

### Rollout

No deployment ordering constraint. T1 (`workspace.yaml`) can merge and be live before any code changes ship — the orchestrator simply reads the new config fields when it next starts. T2–T4 can be deployed together or incrementally; each is independently useful.
