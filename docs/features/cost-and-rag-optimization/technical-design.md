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
- RAG MCP is conditionally wired via `--mcp-config` only when `MCP_RAG_URL` is present in the executor's env. There is no mechanism that guarantees it will be set — the orchestrator passes it only if the operator has manually added it to the executor env.
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
- `budget_usd` is a soft gate — no in-flight task cancellation required.

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

#### 4.4 Orchestrator — auto-inject `MCP_RAG_URL`

In `SubProcessAdapter.submit()`, after reading workspace config:
```ts
if (workspaceConfig.rag?.enabled && workspaceConfig.rag?.url && !input.extraEnv?.MCP_RAG_URL) {
  input.extraEnv = { ...input.extraEnv, MCP_RAG_URL: workspaceConfig.rag.url };
}
```

This ensures RAG MCP is always wired for any run in a workspace where `rag.enabled: true`, without requiring operators to set `MCP_RAG_URL` manually per deployment.

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

#### 4.6 Orchestrator — `budget_usd` dispatch gate

This is the **only real enforcement point** for spend control. Per-run budget checks (both `BUDGET_TOKENS` and cost-based) are post-hoc — they detect overrun after Claude has already exited. The per-feature dispatch gate operates between tasks, where a genuine stop is achievable.

Add optional `budget_usd` to feature `status.yaml` under a `config:` key:
```yaml
config:
  budget_usd: 5.00
```

Before dispatching a new task for a feature:
1. Sum all `cost_usd` values from `run_completed` log entries across all task YAMLs for the feature.
2. If sum >= `budget_usd`, emit `budget_usd_exceeded` event and skip dispatch for this feature until the operator either acknowledges and raises the cap, or cancels remaining tasks.

In-flight tasks are **not** cancelled — there is no safe way to interrupt a running Claude session. Only the next dispatch is blocked.

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
| T3 (orchestrator MCP injection) | T1 — needs `rag` config schema in `workspace.yaml` | Human completes T1 |
| T4 (cost calculation) | T1 — needs `model_pricing` in `workspace.yaml` | Human completes T1 |
| T4 (cost calculation) | T2 — needs `model` field in `result.json` | T2 ships to `workflow` |
| T5 (budget gate) | T4 — needs `cost_usd` in task YAML log | T4 merges |

### External dependencies

None. All changes are within the `workflow` and `management-repo` repos. No third-party API or tooling changes.

### Unresolved decisions

None — both open questions from the product spec are resolved:
1. **Model capture**: from `stream-json` stdout (same events as token extraction) — not via env var. More reliable.
2. **`budget_usd` scope**: pauses new dispatches only. No in-flight cancellation.

---

## 6. Parallelization / Blocking Analysis

```
T1: workspace.yaml — add model_pricing + rag config     [management-repo]
  └── Can begin now — no blockers
  └── Human task; short config edit

T2: Executor — model capture + rag_mcp events + RAG audit extraction     [workflow]
  └── Can begin now — no blockers
  └── T2 and T1 run in parallel

  T3: Orchestrator — auto-inject MCP_RAG_URL from workspace.yaml rag config     [workflow]
      └── BLOCKED on T1 (rag config schema must exist in workspace.yaml before orchestrator reads it)

  T4: Orchestrator — cost calculation + persist token_usage/cost_usd to task YAML     [workflow]
      └── BLOCKED on T1 (model_pricing table must exist in workspace.yaml)
      └── BLOCKED on T2 (model field must be present in result.json)
      └── T3 and T4 run in parallel once T1 and T2 are done

      T5: Orchestrator — budget_usd soft gate on feature dispatch     [workflow]
            └── BLOCKED on T4 (cost_usd must be persisted to task YAML log before cumulative sum is meaningful)
```

T1 and T2 start immediately in parallel. T3 and T4 unblock when T1 and T2 are done respectively. T5 waits on T4. Maximum depth is 3 steps (T1/T2 → T4 → T5).

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `management-repo` | `workspace.yaml` — add `model_pricing`, `rag` sections; add `config.budget_usd` field to feature `status.yaml` template | Config-driven pricing and RAG wiring |
| `workflow` | `runtime/executors/claude/src/token-usage.ts` — add model extraction | Capture model from stream-json |
| `workflow` | `runtime/executors/claude/src/rag-audit.ts` — new file | RAG query event extraction |
| `workflow` | `runtime/executors/claude/src/index.ts` — emit rag_mcp events; call extractRagQueries | Wires new audit module |
| `workflow` | `runtime/abi/src/types.ts` — add `model?` to token_usage | ABI additive extension |
| `workflow` | `runtime/orchestrator/src/adapters/executor/subprocess.ts` — auto-inject MCP_RAG_URL | Reliable RAG wiring |
| `workflow` | `runtime/orchestrator/src/` — result-processing path + budget gate | Cost persistence + dispatch gate |

No changes to `rag-service`, `digital-factory-ui`, or `workflow-backend`.

---

## 8. Validation and Release Impact

### Testing expectations

- `token-usage.ts` already has unit tests. Extend them to assert `model` is extracted correctly.
- Add unit tests for `rag-audit.ts`: fixture stream-json with tool_use/tool_result pairs → verify correct `RagQueryEvent` output.
- Orchestrator integration test: mock result with `token_usage + model` → verify task YAML log entry contains `cost_usd`.
- Orchestrator integration test: mock feature with `config.budget_usd: 0.01` → verify dispatch is paused after first expensive task.

### Migration / config impact

- `workspace.yaml` additions are additive. Orchestrators reading a `workspace.yaml` without `model_pricing` or `rag` fall back gracefully (no cost calculation, no auto-injection).
- `status.yaml` `config.budget_usd` is optional — absence means no budget gate.
- `ExecutorResult` ABI extension is additive (`model?` is optional) — existing executors without model capture still produce valid results.

### Backward compatibility

- All changes are additive. No existing fields are removed or renamed.
- `BUDGET_TOKENS` post-hoc detection continues to work unchanged. Neither `BUDGET_TOKENS` nor per-run `budget_usd` can interrupt an in-flight Claude session — both detect overrun after the run exits. The only real enforcement point is the per-feature `budget_usd` gate (T5), which prevents dispatching the **next** task when cumulative spend is over the cap.

### Rollout

No deployment ordering constraint. T1 (`workspace.yaml`) can merge and be live before any code changes ship — the orchestrator simply reads the new config fields when it next starts. T2–T5 can be deployed together or incrementally; each is independently useful.
