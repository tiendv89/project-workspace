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
- RAG MCP is conditionally wired via `--mcp-config` only when `MCP_RAG_URL` is present in the executor's env. In the Docker Compose stack, `docker-compose.yml` already sets `MCP_RAG_URL: "${MCP_RAG_URL:-http://rag-server:8000}"` — so the executor always gets it when running in the stack. The gap is that the template `.env` has `MCP_RAG_URL=http://rag-server:8000` commented out, making operators think they must set it manually when in fact the compose default already handles it.
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
3. The template `.env` must uncomment `MCP_RAG_URL=http://rag-server:8000` so the default is visible — the compose stack already provides it but the comment implies manual setup is required.
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

### Option A — Compute cost in executor, write `cost_usd` to `result.json` (chosen)

**What it is:** The executor already has the model name (from stream-json) and token counts. It computes `cost_usd` using a hardcoded pricing table and writes it into `result.json` alongside `token_usage`. The orchestrator reads `cost_usd` from the result and persists it to the task YAML — no pricing knowledge anywhere else.

**Pros:** Pricing is co-located with the only process that has all the inputs. The orchestrator stays dumb — it reads and persists, nothing more. No config ceremony. Anthropic's pricing is public and stable; a code deploy for a pricing update is acceptable.

**Cons:** Pricing changes require a code deploy to the executor image.

**Verdict:** Chosen.

---

### Option B — Compute cost in orchestrator with `model_pricing` in `workspace.yaml`

**What it is:** Orchestrator reads `model_pricing` from `workspace.yaml` and computes `cost_usd` when processing the result.

**Pros:** Operator-configurable pricing without a code deploy.

**Cons:** Spreads pricing logic across two components. Adds config ceremony. The orchestrator now needs to know about model pricing, which is executor-domain knowledge. `workspace.yaml` carries data it has no business owning.

**Verdict:** Rejected.

---

### Option C — RAG audit via rag-service middleware (server-side logging)

---

### Option D — RAG audit via rag-service middleware (server-side logging)

**What it is:** The rag-service logs every query it receives — query text, scores, requester identity.

**Pros:** Zero executor changes needed for audit data.

**Cons:** Audit data lives in the rag-service, not co-located with the task run log. Correlating a rag-service query log entry with a specific task run requires a trace ID that doesn't currently exist. Doesn't help with "did the agent use the result?" (hit/miss).

**Verdict:** Rejected for this feature. Server-side logging is complementary and can be added later. The executor-side approach keeps audit data co-located with task run data.

---

## 4. Chosen Design

### Track 1 — Cost accounting

#### 4.1 Executor — model capture + cost calculation

Extend `token-usage.ts` to extract `model` from `assistant` events (same events already parsed for token counts) and compute `cost_usd` using a hardcoded pricing table:

```ts
const PRICING: Record<string, { input_per_mtok: number; output_per_mtok: number }> = {
  'claude-sonnet-4-6':         { input_per_mtok: 3.00,  output_per_mtok: 15.00 },
  'claude-opus-4-7':           { input_per_mtok: 15.00, output_per_mtok: 75.00 },
  'claude-haiku-4-5-20251001': { input_per_mtok: 0.80,  output_per_mtok: 4.00  },
};

export function extractTokenUsage(stdout: string):
  { input: number; output: number; model: string; cost_usd: number } | undefined
```

The last non-null `model` seen across all turns is used (model doesn't change mid-run). If the model isn't in the table, fall back to Sonnet rates and emit a `pricing_fallback` log event. `cost_usd` is computed as:

```
(input / 1_000_000 * input_per_mtok) + (output / 1_000_000 * output_per_mtok)
```

#### 4.2 ABI — extend `ExecutorResult`

Add `cost_usd` to the result schema (additive):

```ts
token_usage?: { input: number; output: number; model: string }
cost_usd?: number
```

The executor writes both fields to `result.json`. The orchestrator reads them as opaque values and persists them — no pricing logic outside the executor.

#### 4.3 Executor — `rag_mcp_registered` / `rag_mcp_unavailable` events

In `index.ts`, after building the MCP config, emit one of:
```json
{ "type": "rag_mcp_registered", "url": "http://rag-server:8000" }
{ "type": "rag_mcp_unavailable", "reason": "MCP_RAG_URL not set" }
```

#### 4.4 Template `.env` — uncomment `MCP_RAG_URL` default

When `--mcp-config` is passed to `claude -p`, the registered MCP tools are available **for the entire session** — Claude can call `mcp__rag-server__rag_query` at any turn, not only from pre-injected briefing context.

The executor already reads `process.env.MCP_RAG_URL` correctly. The Docker Compose template already provides the default:
```yaml
MCP_RAG_URL: "${MCP_RAG_URL:-http://rag-server:8000}"
```

The only fix needed: uncomment `MCP_RAG_URL=http://rag-server:8000` in `templates/.projects/workspace/.env` so operators don't think they must set it manually.

#### 4.5 Orchestrator — persist `token_usage` + `cost_usd` to task YAML

The orchestrator's result-processing path reads `token_usage` and `cost_usd` from `result.json` and writes them into the task YAML log entry. No pricing logic — the values arrive pre-computed from the executor.

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
| T2 (orchestrator persistence) | T1 — needs `cost_usd` in `result.json` ABI | T1 ships to `workflow` |

### External dependencies

None. All changes are within the `workflow` repo only. No `management-repo` changes required.

### Unresolved decisions

None — the one open question from the product spec is resolved:
1. **Model capture**: from `stream-json` stdout (same events as token extraction) — not via env var. More reliable.

Budget enforcement (`budget_usd` dispatch gate) is deferred to a follow-on feature. Accounting correctness ships first.

---

## 6. Parallelization / Blocking Analysis

```
T1: Executor — model capture + cost_usd calculation + rag_mcp events + RAG audit + template .env fix     [workflow]
  └── Can begin now — no blockers

  T2: Orchestrator — persist token_usage + cost_usd from result.json to task YAML     [workflow]
        └── BLOCKED on T1 (cost_usd + model must be present in result.json / ABI before orchestrator can persist them)
```

T1 starts immediately. T2 unblocks when T1 is merged. Maximum depth is 2 steps (T1 → T2). Both tasks touch only the `workflow` repo.

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `workflow` | `runtime/executors/claude/src/token-usage.ts` — add model extraction + cost calculation | Capture model + compute cost_usd |
| `workflow` | `runtime/executors/claude/src/rag-audit.ts` — new file | RAG query event extraction |
| `workflow` | `runtime/executors/claude/src/index.ts` — emit rag_mcp events; call extractRagQueries; write cost_usd to result.json | Wire audit + cost |
| `workflow` | `runtime/orchestrator/templates/.projects/workspace/.env` — uncomment `MCP_RAG_URL` default | Make compose default visible |
| `workflow` | `runtime/abi/src/schema.ts` — add `model` to token_usage, add `cost_usd` | ABI additive extension |
| `workflow` | `runtime/orchestrator/src/` — result-processing path: persist token_usage + cost_usd | Cost persistence into task YAML log |

No changes to `rag-service`, `digital-factory-ui`, or `workflow-backend`.

---

## 8. Validation and Release Impact

### Testing expectations

- `token-usage.ts` already has unit tests. Extend them to assert `model` is extracted and `cost_usd` is computed correctly for known models and falls back gracefully for unknown ones.
- Add unit tests for `rag-audit.ts`: fixture stream-json with tool_use/tool_result pairs → verify correct `RagQueryEvent` output.
- Orchestrator integration test: mock result.json with `token_usage + cost_usd` → verify task YAML log entry persists both values unchanged.

### Migration / config impact

- `ExecutorResult` ABI extension is additive (`cost_usd` and `model` are optional) — existing executors that don't compute cost still produce valid results; the orchestrator just skips persisting those fields if absent.

### Backward compatibility

- All changes are additive. No existing fields are removed or renamed.
- `BUDGET_TOKENS` post-hoc detection continues to work unchanged. Budget enforcement is deferred — this feature only adds accurate accounting (tokens + cost persisted to task YAML). A follow-on feature will add the dispatch gate once the accounting data is trusted.

### Rollout

T1 (executor) can ship and be tested independently — `cost_usd` appears in `result.json` immediately. T2 (orchestrator persistence) can follow once T1 is merged; until then cost data exists in result.json but isn't yet written to task YAML logs.
