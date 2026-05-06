# Technical Design

## Feature
- Feature ID: `gitnexus-mcp-integration`
- Title: GitNexus Code-Graph MCP Integration

## Current State
The executor (`runtime/executors/claude/src/index.ts`) builds an MCP config from up to two sources:
- `rag-server` — SSE transport, enabled via `MCP_RAG_URL` env var
- `figma` — stdio transport, enabled via `FIGMA_PERSONAL_ACCESS_TOKEN` env var

GitNexus is not yet wired.

## Constraints
- GitNexus has no incremental indexing — `gitnexus analyze` must rerun on every task start.
- `gitnexus analyze` takes 30–120s depending on repo size; must not fail the task if it times out or errors.
- GitNexus license is PolyForm Noncommercial — acceptable for internal/platform use; must be noted for enterprise customers.
- The executor image must have Node.js available (already true) to run `npx gitnexus@latest`.

## Options Considered

### Option A — npx on demand (no image change)
Run `npx -y gitnexus@latest analyze <taskRepoPath>` each task start; start the MCP server via `npx -y gitnexus@latest mcp` as a stdio process.

- Pros: zero image changes; always latest GitNexus version.
- Cons: npx download on cold start adds latency; network dependency at runtime.

### Option B — pre-install in executor image
Add `gitnexus` to the executor Dockerfile `RUN npm install -g gitnexus`.

- Pros: faster cold start; no network dependency.
- Cons: image rebuild required on GitNexus updates; ties executor image version to GitNexus version.

### Option C — sidecar container
Run GitNexus as a separate Docker service (like rag-server), exposed over HTTP/SSE.

- Pros: clean separation; could support multi-repo graphs.
- Cons: significant complexity; GitNexus MCP is stdio-native, not HTTP-first; overkill for v1.

## Chosen Design
**Option A** for v1. Simple, no image changes, opt-in via `GITNEXUS_ENABLED=1`. If startup latency proves problematic, migrate to Option B.

## Implementation Plan

### 1. Executor changes (`workflow` repo — `runtime/executors/claude/src/index.ts`)
- Read `GITNEXUS_ENABLED` env var.
- After step 1 (repo materialization), if enabled: run `npx -y gitnexus@latest analyze <taskRepoPath>` (timeout 120s, stdio: pipe). Emit `gitnexus_indexing_start` / `gitnexus_indexing_done` / `gitnexus_indexing_failed` events. On failure: log and continue without GitNexus (non-fatal).
- In step 5 (MCP config), if `gitnexusReady`: add `gitnexus` stdio server entry (`npx -y gitnexus@latest mcp`).
- Update condition from `if (mcpRagUrl || figmaToken)` → `if (mcpRagUrl || figmaToken || gitnexusReady)`.

### 2. Env/config templates (`workflow` repo — `runtime/orchestrator/templates/`)
- `.projects/.env.example`: add `# GITNEXUS_ENABLED=` with comment.
- `docker-compose.yml`: add `GITNEXUS_ENABLED: "${GITNEXUS_ENABLED:-}"` to base anchor and all three agent overrides.

### 3. Executor header comment update
- Add `GITNEXUS_ENABLED` to the "Day-1 single-container extras" block comment in `index.ts`.

## Dependency Analysis
- No dependencies on other in-flight features.
- Depends on GitNexus npm package availability (`gitnexus@latest` on npmjs.com).

## Parallelization / Blocking Analysis
All three changes are in the same repo (`workflow`) and can land in a single PR from a single task. No parallel tasks needed.
