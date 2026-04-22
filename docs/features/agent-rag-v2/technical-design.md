# Technical Design: Agent RAG v2 — Source Code + Docs Indexing

## Feature
- Feature ID: `agent-rag-v2`
- Status: **draft** — awaiting human approval

---

## 1. Current State

The v1 RAG stack (`agent-rag-mcp`) is fully deployed and running across the workspace. It consists of three services in the `rag-service` repo:

- **qdrant** — vector database (`qdrant/qdrant` Docker image, port 6333), one collection per `workspace_id`
- **rag-server** — FastAPI + FastMCP service; exposes `rag_query(query, workspace_id, top_k, source_types)` over HTTP/SSE
- **indexer** — polling worker; detects changed files via `git diff`, chunks, embeds via `sentence-transformers/all-MiniLM-L6-v2` (384-dim), upserts to Qdrant

**What v1 indexes today:**

| Pattern | `source_type` | Chunking |
|---|---|---|
| `workflow/workflow_skills/*/SKILL.md` | `skill` | Whole file |
| `workflow/technical_skills/*/SKILL.md` | `skill` | Whole file |
| `docs/features/*/product-spec.md` | `product_spec` | 512 tok / 50 overlap |
| `docs/features/*/technical-design.md` | `technical_design` | 512 tok / 50 overlap |
| `agents/*/log.jsonl` | `task_log` | One chunk per JSONL entry |
| `CLAUDE.md`, `CLAUDE.shared.md` | `claude_md` | Whole file |
| `README.md` (top-level only) | `readme` | 512 tok / 50 overlap |

**What v1 explicitly does NOT index:** source code, `docs/` folder content (other than the specific feature paths above), `node_modules/`, `vendor/`, binaries, `.env` files.

**Current limitations:**
- `docs/architecture/`, `docs/guides/`, `docs/adr/`, and any other `docs/` content is invisible to the index
- All implementation files (`.py`, `.ts`, `.go`, `.tsx`, etc.) are unindexed — agents do cold discovery via grep/read on every task
- `classify_path()` in `source_mapper.py` returns `None` for any path not matching the 7 inclusion patterns; those files are silently skipped

**v1 VALID_SOURCE_TYPES** (hardcoded in `services/shared/schema.py`):
```python
frozenset({"skill", "task_log", "product_spec", "technical_design", "readme", "claude_md"})
```

Any new source type must be added here before the indexer can write points with that type.

---

## 2. Problem Framing

**Must change:**
- `VALID_SOURCE_TYPES` must include `doc` and `source_code`
- `source_mapper.py` must match `docs/**/*.md` files (excluding the already-covered `docs/features/*/product-spec.md` and `docs/features/*/technical-design.md`) and source code files
- `chunker.py` must handle the two new source types
- Source code chunks must be semantically meaningful — not arbitrary 512-token windows that split a function in half

**Must remain stable:**
- `rag_query` MCP tool contract (signature, return shape) — agents already call this; breaking it would require updating every agent's tooling
- Qdrant `workspace_id` isolation — every point carries `workspace_id`; filtering is mandatory on every query
- The polling indexer model — no change to the trigger mechanism

**Fixed assumptions:**
- Qdrant is already running and collections already exist; re-indexing happens naturally on the next poll cycle after the indexer is updated
- The embedding model is `all-MiniLM-L6-v2` (384-dim); any change to the model or dimension requires dropping and recreating the Qdrant collection — a migration concern
- The `rag-service` repo owns all three services

---

## 3. Options Considered

### 3a. Chunking strategy for source code

**Option A — Sliding window (same as prose)**
- Apply the existing `_sliding_window_chunks(512 tok, 50 overlap)` to source files
- Pros: zero new code, immediate
- Cons: arbitrarily splits functions mid-body; a chunk containing the middle of a function body with no signature is nearly useless for retrieval; embedding quality degrades with decontextualised fragments
- Verdict: Fast to ship, but poor retrieval quality — agents will get chunks without function names or class context

**Option B — AST-aware chunking via tree-sitter**
- Parse each source file with `tree-sitter` and extract top-level nodes (functions, classes, methods)
- Each function/class becomes its own chunk, optionally prefixed with its parent class name for context
- Falls back to sliding window for languages without a tree-sitter grammar
- Pros: chunks are semantically complete — each chunk is a named, callable unit with full signature; retrieval quality is significantly better; "how does X work" queries return the actual function
- Cons: new dependency (`tree-sitter` + per-language grammar packages); parsing can fail on malformed code (fallback handles this)
- Grammar packages needed for the current repos: `tree-sitter-python`, `tree-sitter-typescript` (covers `.ts` and `.tsx`), `tree-sitter-go`
- Verdict: right choice for production use; fallback to sliding window means failure is graceful

**Option C — LLM-based summarization per function (Hermes-style)**
- Call the LLM on each function to produce a natural-language summary, index the summary instead of the raw code
- Pros: very high retrieval quality for semantic questions; noise-free
- Cons: enormous indexing cost (API call per function × all functions in all repos × every re-index cycle); not feasible for a polling indexer at 5-min intervals; latency makes full re-index impractical
- Verdict: interesting for a future "summarize on first index" mode; not viable for v2 polling indexer

**Chosen: Option B (AST-aware chunking, tree-sitter, fallback to sliding window).**

---

### 3b. Retrieval strategy

**Option A — Pure dense vector search (current approach, extended to code)**
- Keep `all-MiniLM-L6-v2`, add code to the index, search by cosine similarity
- Pros: no change to Qdrant, no change to query layer
- Cons: `all-MiniLM-L6-v2` is trained on prose, not code; exact identifier lookup ("find `AuthService.validate_token`") may score poorly vs. semantically unrelated prose chunks
- Verdict: acceptable for semantic questions, weak for exact lookup

**Option B — Hermes Agent (NousResearch) as the agent runtime + memory layer**
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) is a self-improving AI agent platform with a built-in learning loop: agents create skills from experience, skills self-improve during use, and cross-session recall is provided via FTS5 (SQLite full-text search) + LLM summarization
- Its memory architecture is the direct prior art for what this system is building: task logs become searchable, skills are refined automatically, and agents accumulate a model of the codebase across sessions
- Two ways this could apply:
  1. **Replace the agent runtime** — run agents on Hermes instead of Claude Code + the current workflow skills; Hermes' built-in memory/skill loop handles RAG natively
  2. **Adopt only the FTS5 retrieval approach** — drop Qdrant; store chunks in SQLite with FTS5 BM25 scoring; use Hermes' proven retrieval logic as a reference implementation
- Pros (runtime replacement): no RAG infra to build or maintain; Hermes' learning loop is production-proven (107k stars); skill self-improvement is richer than static `SKILL.md` files
- Cons (runtime replacement): Hermes is a full agent platform — adopting it means replacing Claude Code, the claim/task YAML protocol, `start-implementation`, all workflow skills, and human governance gates. This is not a retrieval upgrade; it is a complete workflow rewrite. Not feasible for v2.
- Pros (FTS5 approach only): zero infra (SQLite file), exact keyword matching, BM25 scoring, no embedding model latency, no Qdrant dependency
- Cons (FTS5 approach only): no semantic search — "how does this codebase handle retries?" fails if the code says `backoff` not `retry`; prose documents (specs, skills, task logs) benefit from semantic similarity which FTS5 cannot provide; complete infrastructure replacement for the existing working stack
- Verdict: Hermes is the clearest external validation that agent memory + skill learning produces better agents. Its FTS5 approach is the right answer for pure code identifier search; it is the wrong answer for semantic recall across prose docs. The current system needs both. **Hermes' architecture is the target end-state for v3+; FTS5 as a code-only backend is worth revisiting once hybrid search is in place (see Option D).**

**Option C — FTS5 / SQLite for source code only (split backend)**
- Keep Qdrant for prose (skills, specs, task logs, docs) — semantic search is valuable here
- Add a separate SQLite FTS5 index for source code only — exact identifier + BM25 search
- Expose a second MCP tool `code_search(query, workspace_id, top_k)` alongside `rag_query`
- Pros: best-of-both — semantic recall for prose, exact recall for code; zero new infra (SQLite is embedded)
- Cons: two backends to maintain; two MCP tools agents must learn to use; agents may not know which tool to call
- Verdict: architecturally sound but adds agent-facing complexity; better addressed via hybrid search in one tool (Option D)

**Option D — Hybrid search (Qdrant dense + BM25 sparse)**
- Qdrant 1.9+ supports sparse vectors; index both a 384-dim dense vector and a BM25 sparse vector per chunk
- At query time, combine scores via Reciprocal Rank Fusion (RRF) — one tool, two signals
- Pros: semantic + exact in one query, one backend, one tool; the Hermes FTS5 benefit absorbed without splitting the system
- Cons: requires dropping and recreating the Qdrant collection (schema change for sparse vector field); requires a BM25 tokenizer at index time; `qdrant-client >= 1.9` already satisfied
- Verdict: this is the right long-term architecture — it merges the Hermes FTS5 insight with the current semantic stack

**Option E — Upgrade embedding model**
- Replace `all-MiniLM-L6-v2` (384-dim) with a model that handles both code and prose well
- Best candidates:
  - `BAAI/bge-base-en-v1.5` — 768-dim, strong general + code retrieval, no special flags required, well-supported in sentence-transformers
  - `nomic-embed-text-v1.5` — 768-dim, excellent mixed code+prose, supports matryoshka (can truncate to 512/256 if needed); requires `trust_remote_code=True`
  - `all-mpnet-base-v2` — 768-dim, better than MiniLM for prose, weaker on code than the above two
- Migration cost: dropping and recreating the Qdrant collection is a one-time operational step — stop indexer, drop collection, restart, wait one poll cycle for full re-index. Not a real blocker.
- Pros: significantly better retrieval quality for both code and prose with a single model swap; no architecture change; Option D (hybrid) still available as a v3 upgrade on top of the better model
- Cons: ~2x memory and compute for embeddings; ~300–400 MB model download vs ~90 MB for MiniLM; first re-index after migration takes one full cycle

**Chosen: Option E (upgrade to `BAAI/bge-base-en-v1.5`, 768-dim) combined with dense search, with Option D as the documented v3 upgrade.**

Rationale: going into v2 with a 384-dim prose-trained model while deliberately adding source code is a quality risk that would undermine the feature's core goal. `all-MiniLM-L6-v2` was chosen for v1 when no code was indexed; that constraint no longer holds. `BAAI/bge-base-en-v1.5` is the pragmatic upgrade — strong on both code and prose, no unusual loading flags, same sentence-transformers interface. The migration is a one-time collection recreation. Option D (hybrid dense + sparse BM25) remains the v3 path for near-perfect recall.

---

### 3c. Docs folder scope

**Option A — All `docs/**/*.md` files**
- Index every Markdown file under `docs/` in every repo
- Avoids per-feature `product-spec.md` and `technical-design.md` (already covered as `product_spec` / `technical_design`)
- New `source_type: doc`

**Option B — Curated exclusion list**
- Same as A, but exclude known-noisy paths (e.g. `docs/features/*/tasks.md`)
- `tasks.md` is machine-generated planning; its content is covered by individual task YAMLs already indexed as `task_log`

**Chosen: Option B.** Index all `docs/**/*.md` except `docs/features/*/product-spec.md`, `docs/features/*/technical-design.md`, and `docs/features/*/tasks.md` (those are already covered or redundant).

---

## 4. Chosen Design

### Summary

Extend the `rag-service` indexer with two new source types, upgrade the embedding model from `all-MiniLM-L6-v2` (384-dim) to `BAAI/bge-base-en-v1.5` (768-dim), and update the `start-implementation` skill in the `workflow` repo to query the new source types at claim time. The Qdrant collection is recreated once for the dimension change; the `rag_query` tool contract is unchanged.

### New source types and patterns

| Pattern | `source_type` | Chunking |
|---|---|---|
| `docs/**/*.md` (excl. product-spec, technical-design, tasks.md) | `doc` | 512 tok / 50 overlap |
| `**/*.py`, `**/*.ts`, `**/*.tsx`, `**/*.go`, `**/*.js` (excl. vendor, node_modules, build, dist, .env) | `source_code` | AST-aware (tree-sitter), fallback to 512/50 sliding window |

### Schema change

Add to `VALID_SOURCE_TYPES` in `services/shared/schema.py`:
```python
frozenset({
    "skill", "task_log", "product_spec", "technical_design",
    "readme", "claude_md",
    "doc",          # new
    "source_code",  # new
})
```

Update `VECTOR_DIM` in `services/shared/qdrant_init.py`:
```python
VECTOR_DIM = 768  # upgraded from 384 (BAAI/bge-base-en-v1.5)
```

**Collection migration:** The dimension change requires dropping and recreating the Qdrant collection. The indexer's first run after deployment performs a full re-index (no prior `_last_commit`), so existing content is restored automatically within one poll cycle. Procedure:
1. Stop indexer
2. Drop collection: `DELETE /collections/{workspace_id}` on the Qdrant REST API
3. Deploy new indexer image
4. Indexer recreates collection at 768-dim and re-indexes all content on startup

### AST-aware code chunking

`services/indexer/chunker.py` gets a new strategy for `source_code`:

1. Attempt to parse the file with tree-sitter using the appropriate grammar (inferred from file extension)
2. Walk top-level nodes: `function_definition`, `class_definition`, `method_definition`, `function_declaration`
3. For each node, emit a chunk:
   - Prefix with `# <file_path>` and `# class: <ClassName>` if applicable, then the raw node text
   - This context prefix ensures the embedding captures the file location and class membership, not just the isolated body
4. If tree-sitter fails (parse error, unsupported language) or yields zero nodes: fall back to `_sliding_window_chunks(512, 50)`
5. Very large functions (> 1500 tokens ≈ 6000 chars) are split with a sliding window within the function body, each sub-chunk prefixed with the function signature line

**New dependencies:**
```
tree-sitter>=0.23.0
tree-sitter-python>=0.23.0
tree-sitter-typescript>=0.23.0
tree-sitter-go>=0.23.0
```

### Embedding model upgrade

Replace `sentence-transformers/all-MiniLM-L6-v2` with `BAAI/bge-base-en-v1.5` in both `services/indexer/embedder.py` and `services/rag_server/embedder.py`:

```python
# before
MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"  # 384-dim

# after
MODEL_NAME = "BAAI/bge-base-en-v1.5"  # 768-dim
```

`bge-base-en-v1.5` uses the standard `SentenceTransformer` interface with no special flags. Model download is ~440 MB (vs ~90 MB for MiniLM) — consider pre-baking into the Docker image to avoid slow first-start. The `sentence-transformers` package version constraint is unchanged (`>=3.0.0`).

### Source code exclusion filters

Added to `_EXCLUDE_PATTERNS` in `source_mapper.py`:
- `__pycache__/`
- `dist/`, `build/`, `.next/`, `out/` (build artifacts)
- `migrations/` (auto-generated DB migrations)

**Test files are explicitly included.** `*.test.ts`, `*.spec.ts`, `*.test.py` and similar are indexed. Test files show exactly how functions are called — they are often the most accurate usage documentation in the codebase and directly answer "how do I call X?" queries.

### Claim-time context injection update

`workflow_skills/start-implementation/SKILL.md` calls `rag_query` without a `source_types` filter and that stays as-is. Agents are always implementing, so returning all source types on every query is the correct default — no filter needed.

### What does NOT change

- `rag_query` tool signature — identical
- Qdrant collection name and distance metric (COSINE) — identical; only the vector dimension changes
- `workspace_id` isolation — unchanged
- Polling interval, `git diff`-based change detection — unchanged
- Docker Compose structure, env vars — unchanged (no new services, no new env vars)

---

## 5. Dependency Analysis

**Internal dependencies:**
- `VALID_SOURCE_TYPES` in `schema.py` must be updated before the indexer can write points with `doc` or `source_code` types (raises `ValueError` on upsert otherwise) — T1 must precede T2 and T3
- Tree-sitter grammars must be pinned to the same minor version as `tree-sitter` core — version mismatch causes runtime import errors

**External dependencies:**
- `tree-sitter >= 0.23.0` — Python bindings for the tree-sitter parsing library; MIT licence; well-maintained
- `tree-sitter-python`, `tree-sitter-typescript`, `tree-sitter-go` — grammar packages; each is a thin Python wrapper around a C grammar; Apache 2.0 / MIT
- Docker image rebuild required to install new packages — indexer container must be rebuilt and redeployed; existing Qdrant data is unaffected

**Blocking decisions — resolved:**
- Chunking strategy for code: AST-aware with tree-sitter (chosen above)
- Retrieval strategy: dense-only for v2, hybrid planned for v3 (chosen above)
- Docs scope: all `docs/**/*.md` excluding already-covered and redundant files (chosen above)

**Configuration dependencies:**
- No new env vars required
- Qdrant collection recreation required — `VECTOR_DIM` changes from 384 to 768 (see section 4, Schema change)
- Indexer container rebuild and restart is the only operational change

**Release dependencies:**
- Independent of all other in-flight features
- `agent-rag-mcp` (v1) must be deployed and stable before v2 is applied — v2 is a backwards-compatible extension of the same service

---

## 6. Parallelization / Blocking Analysis

```
T1: Schema + model upgrade — VALID_SOURCE_TYPES, VECTOR_DIM, embedder swap, collection migration (rag-service)
  └── Can begin now — no blockers

  T2: Docs folder indexing — source_mapper + chunker (rag-service)
  T3: Source code indexing — tree-sitter AST chunking (rag-service)
      └── T2 and T3 run in parallel
      └── BLOCKED on T1 (schema.py must recognise the new types; VECTOR_DIM must match the
          deployed model before any new points are written)
```

T2 and T3 are the bulk of the work and can be executed by two agents concurrently once T1 is merged. T1 is the critical-path task — it owns the one-time collection migration and the model swap. No workflow repo changes are required.

---

## 7. Repository Impact

| Repo | Files changed | Reason |
|---|---|---|
| `rag-service` | `services/shared/schema.py` | Add `doc`, `source_code` to `VALID_SOURCE_TYPES`; update `VECTOR_DIM` to 768 |
| `rag-service` | `services/indexer/embedder.py` | Swap model to `BAAI/bge-base-en-v1.5` |
| `rag-service` | `services/rag_server/embedder.py` | Swap model to `BAAI/bge-base-en-v1.5` |
| `rag-service` | `services/indexer/source_mapper.py` | Add docs + code inclusion patterns; extend exclusion list |
| `rag-service` | `services/indexer/chunker.py` | Add `doc` strategy (sliding window) and `source_code` strategy (tree-sitter AST, fallback) |
| `rag-service` | `requirements.txt` | Add `tree-sitter>=0.23.0` and grammar packages |
| `rag-service` | `tests/indexer/test_source_mapper.py` | Tests for new path patterns |
| `rag-service` | `tests/indexer/test_chunker.py` | Tests for new chunking strategies |
| `rag-service` | `tests/shared/test_schema.py` | Tests for updated source type validation and vector dimension |

---

## 8. Validation and Release Impact

**Testing expectations:**
- Unit: `classify_path("docs/architecture/overview.md")` → `("doc", None)`; `classify_path("services/auth.py")` → `("source_code", None)`; `classify_path("node_modules/foo.js")` → `None`
- Unit: `chunk_document("source_code", <python_file>)` produces chunks whose content starts with the function signature, not a mid-body fragment
- Unit: `chunk_document("source_code", <malformed_file>)` falls back to sliding window without raising
- Integration: index a Python file → query `rag_query("authentication function", workspace_id="workspace", source_types=["source_code"])` → top result contains the auth function body
- Integration: index a `docs/architecture/overview.md` → query returns it
- Regression: existing source types (skill, product_spec, etc.) still return correct results after schema update

**Migration / config impact:**
- **Qdrant collection recreation required** — `VECTOR_DIM` changes from 384 to 768; existing collection must be dropped and recreated. Procedure: stop indexer → `DELETE /collections/{workspace_id}` → deploy new image → indexer recreates collection and re-indexes on first run
- Indexer and rag-server containers must both be rebuilt (both embedder files change)
- First indexer run after deployment performs a full re-index (cold start) — all content restored within one poll cycle
- Existing agents with `MCP_RAG_URL` set automatically benefit once the indexer run completes; no agent config changes required

**Rollout concerns:**
- Model download increases from ~90 MB to ~440 MB — pre-bake `BAAI/bge-base-en-v1.5` into the Docker image to avoid slow first-start
- Tree-sitter grammar packages add ~5–10 MB to the container image
- Repos with very large codebases (> 100k LOC) may see longer full re-index cycles — monitor indexer logs
- Test files are included — they document real usage patterns and are treated as first-class indexed content
- Brief cold-start window between collection drop and first re-index completion — agents degrade gracefully (empty results, not errors)

**Backward compatibility:**
- `rag_query` tool contract is unchanged
- The collection recreation is a one-time migration with a brief cold-start window; not a rolling upgrade
- No workflow repo changes — `start-implementation` skill is unchanged

**v3 upgrade path (not in scope for v2):**
- Hybrid search (Qdrant dense + sparse BM25) — switch to `nomic-embed-text-v1.5` or `all-mpnet-base-v2`, enable sparse vectors, query with RRF fusion; requires collection recreation and full re-index

---

## 9. Addendum — Fix 2: Runtime Pre-injection via REST Query Endpoint (2026-04-22)

### Problem

After full deployment of T1–T3, telemetry shows 0 actual calls to `mcp__rag-server__rag_query` across all agent sessions. Infrastructure is working (2,918 points indexed, MCP connection confirmed, tool visible in tool list), but the model consistently skips the call. The `start-implementation` skill instructs the model to call the tool, but graceful-degradation language ("skip if unavailable") provides sufficient cover for the model to elide the step under implementation pressure.

The fix must be independent of model behaviour: inject RAG context before Claude is ever invoked, not as a tool the model is asked to call.

### Solution

Two-part change:

1. **`rag-service`** — expose a plain HTTP `POST /query` endpoint alongside the existing MCP/SSE interface. Same retrieval logic, plain JSON in/out, no SSE.
2. **`workflow`** — in `agent-runtime/src/main.ts`, after `generateAgentContext()` and before `runClaude()`, call `POST ${MCP_RAG_URL}/query`, receive chunks, and append a `## RAG Context` section to `agentContext`. The enriched string is passed unchanged into `runClaude()` as the agent's briefing.

### REST endpoint design (`rag-service`)

**Route:** `POST /query` on the existing FastAPI app that backs the FastMCP server.

**Request body:**
```json
{
  "query":        "string",
  "workspace_id": "string",
  "top_k":        5,
  "source_types": ["skill", "source_code", "doc"]   // optional, omit = all types
}
```

**Response (200):**
```json
{
  "results": [
    {
      "content":  "string",
      "score":    0.87,
      "metadata": {
        "source_type": "skill",
        "repo":        "workflow",
        "file_path":   "workflow_skills/start-implementation/SKILL.md",
        "feature_id":  null
      }
    }
  ]
}
```

**Error responses:** 422 for malformed input (FastAPI default); 500 with `{"error": "..."}` for Qdrant failures. The caller treats any non-2xx as a graceful-degradation trigger.

**Implementation:** the route handler calls the same internal `_rag_query(query, workspace_id, top_k, source_types)` function already used by the MCP tool. No new retrieval logic; this is a thin HTTP wrapper.

**No auth.** The endpoint is on the Docker-internal network; the same trust model as the existing SSE endpoint.

### Runtime injection design (`workflow`)

**New function:** `agent-runtime/src/bootstrap/fetch-rag-context.ts`

```typescript
export async function fetchRagContext(
  ragBaseUrl: string,
  query: string,
  workspaceId: string,
  topK = 5,
): Promise<string>
```

- POSTs to `${ragBaseUrl}/query`
- On 2xx: formats results as a `## RAG Context\n\n<chunk>\n---\n...` block and returns it
- On any error (network failure, non-2xx, timeout): logs a warning and returns `""` — never throws

**Injection in `main.ts`** (between `generateAgentContext` and `runClaude`):

```typescript
const baseAgentContext = generateAgentContext({ ... });

const ragBaseUrl = process.env.MCP_RAG_URL;
const ragBlock = ragBaseUrl
  ? await fetchRagContext(ragBaseUrl, `${task.title} ${featureId}`, workspaceId)
  : "";

const agentContext = ragBlock ? `${baseAgentContext}\n\n${ragBlock}` : baseAgentContext;
```

`workspaceId` is read from `workspace.yaml` (the `workspace_id` field), which `main.ts` already parses.

**No new env var required.** `MCP_RAG_URL` already controls whether RAG is active; if it is set, pre-injection is active. If it is not set, behaviour is identical to the current state.

### Graceful degradation

| Failure mode | Behaviour |
|---|---|
| `MCP_RAG_URL` unset | Skip injection entirely — no change from current behaviour |
| Network unreachable | `fetchRagContext` catches, logs, returns `""` — agent runs without pre-injected context |
| Non-2xx response | Same as above |
| Timeout (>3 s) | Same as above — inject a 3 s `AbortSignal` on the fetch call |
| Empty results (0 chunks) | No block appended — agent runs without pre-injected context |

The MCP tool registration in `run-claude.ts` is unchanged — agents can still call `rag_query` for follow-up queries during task execution.

### What does NOT change

- MCP tool registration and SSE endpoint — unchanged
- `generateAgentContext` signature — unchanged (still synchronous pure function)
- `runClaude` signature — `agentContext` parameter type is `string`, unchanged
- `start-implementation` skill — no changes required (pre-injection makes the tool call optional)
- Docker Compose, env vars, Qdrant schema — no changes

---

## 10. Updated Dependency Analysis (post-addendum)

```
T1, T2, T3 — DONE (merged)

T4: REST query endpoint (rag-service)
  └── No blockers — can begin immediately

  T5: Runtime pre-injection (workflow)
      └── BLOCKED on T4 (endpoint shape must be confirmed before the fetch client is written)
```

T4 and T5 are the only remaining tasks. T4 is unblocked. T5 depends on T4.

## 11. Updated Repository Impact

| Repo | Files changed | Reason |
|---|---|---|
| `rag-service` | `services/rag_server/server.py` | Add `POST /query` route |
| `rag-service` | `tests/rag_server/test_query_endpoint.py` | Unit + integration tests for new route |
| `workflow` | `agent-runtime/src/bootstrap/fetch-rag-context.ts` | New fetch helper |
| `workflow` | `agent-runtime/src/main.ts` | Call `fetchRagContext`, append block to `agentContext` |
| `workflow` | `agent-runtime/src/bootstrap/agent-context.ts` | No change (stays pure/sync) |
| `workflow` | `agent-runtime/tests/bootstrap/fetch-rag-context.test.ts` | Unit tests for helper |
