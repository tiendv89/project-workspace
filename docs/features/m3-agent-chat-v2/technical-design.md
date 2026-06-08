# Technical Design

## Feature
- Feature ID: `m3-agent-chat-v2`
- Title: Agent Chat v2 — Session History, Enriched Context, and IDE-style Layout

---

## 1. Current State

### hermes-agent (`base_branch: main`)

**`workflow_gateway/`** — FastAPI gateway wrapping `AIAgent`. Two live routes:
- `POST /api/v5/create_session` — creates a row in `sessions` table, returns `session_id`.
- `POST /api/v5/stream_chat` — loads message history, runs one `AIAgent` turn, streams SSE.

**Session store** (`workflow_gateway/db/`) — SQLAlchemy async (asyncpg). Tables: `sessions`, `messages` (see `database/hermes-agent/schema.dbml`). Sessions carry `workspace_id` and `feature_id` as TEXT slugs. No list endpoint exists.

**`workflow_plugin/`** — Hermes plugin with four tools:
- `workflow_get_workspace_context` — psycopg sync read of `workspaces` from `WORKFLOW_DATABASE_URL`.
- `workflow_get_feature_state` — psycopg sync read of `workspace_features`.
- `workflow_write_product_spec` / `workflow_write_technical_design` — GitHub Contents API PUT.

**`workflow_plugin/db.py`** — uses `psycopg` (synchronous) with `WORKFLOW_DATABASE_URL` pointing at the **workspace** Postgres instance (separate from the hermes-agent gateway's asyncpg connection). The plugin has no access to live task data — `workspace_tasks` is never queried.

**`workflow_plugin/hooks.py`** — `inject_context` pre_llm_call hook. Injects `workspace_id`, `feature_id`, repo list, and feature stage into system prompt. No task-level data.

### workflow-backend

**`internal/handler/chat_proxy.go`** — `ChatProxyHandler` with two routes:
- `POST /api/workspaces/:wid/features/:fid/chat/session`
- `POST /api/workspaces/:wid/features/:fid/chat`

No session-listing route exists. The handler pattern is a transparent byte-pipe proxy.

### digital-factory-ui

**`FeatureSessionPage.tsx`** — two-column layout: `flex > [center flex-1] + [right w-96]`. Right slot is `AgentChatPanel`.

**`AgentChatPanel.tsx`** — creates a fresh session on mount (`createChatSession`), holds a flat `messages` array in React state. No session history, no back navigation. Session ID lives only in component state — lost on unmount.

**`src/services/workflow-backend/chat.ts`** — `createChatSession()` and `streamChatTurn()`. No `listChatSessions()`.

**`src/services/workflow-backend/client.ts`** — `searchFeatureTasks(workspaceId, featureId)` → `GET /api/workspaces/:wid/features/:fid/tasks` already exists. No new API needed for the left panel task list.

---

## 2. Problem Framing

### What needs to change

1. **hermes-agent gateway** needs a `GET /api/v5/sessions` endpoint listing sessions by `workspace_id` + `feature_id`.
2. **hermes-agent workflow_plugin** needs three new tools (`workflow_get_tasks`, `workflow_query_gitnexus`, `workflow_query_rag`) and an updated `inject_context` hook that includes live task data.
3. **workflow-backend** needs one new proxy route: `GET /chat/sessions`.
4. **digital-factory-ui** needs:
   - A new `FeatureStatusPanel` left panel (feature stage + task list using existing `searchFeatureTasks`).
   - `FeatureSessionPage` reshaped into a three-panel shell with collapse toggles.
   - `AgentChatPanel` refactored into a `history ↔ active` state machine with `SessionHistoryList`.
   - `listChatSessions()` added to `chat.ts`.

### What must remain stable

- All existing workflow-backend routes and the chat proxy byte-pipe pattern.
- The `AgentChatPanel` `onArtifactSaved` callback and `FeatureTabView` invalidation flow.
- The SSE event envelope (unchanged from v1).
- `workflow_plugin` existing four tools — additions only, no renames.
- The hermes-agent `create_session` / `stream_chat` API contract.

### Fixed assumptions

- `WORKFLOW_DATABASE_URL` points at the workspace Postgres instance (already used by `workflow_plugin/db.py`). `workspace_tasks` is queryable from it — no new DB connection needed for `workflow_get_tasks`.
- `GITNEXUS_MCP_URL` and `RAG_MCP_URL` are optional env vars pointing at each service's
  `/sse` endpoint. If absent, the tool's `check_fn` returns `False` and `get_definitions`
  omits it from the tool list (verified mechanism — see §3 Option C).
- GitNexus and RAG are reached over the **MCP SSE transport** via the `mcp` Python
  `ClientSession` (open `/sse` → `initialize` → `call_tool`), **not** a stateless
  JSON-RPC POST. git-nexus is SSE-only; rag-service also offers a `/query` REST route but
  the uniform MCP path is chosen (§3 Option C). The handlers are async, bridged to the
  sync tool-dispatch path by the registry's `_run_async`.
- hermes-agent gateway DB is asyncpg (SQLAlchemy async). The new `list_sessions` store function follows the existing async pattern.
- digital-factory-ui uses TailwindCSS v4 + HeroUI v3 — collapse animation via `transition-[width]` utility.

---

## 3. Options Considered

### Session list — Option A: workflow-backend queries hermes-agent DB directly
workflow-backend adds `HERMES_DATABASE_URL` and queries `sessions` table directly in Go.

- **Pro:** one fewer round-trip.
- **Con:** cross-service DB access — breaks encapsulation. workflow-backend must know hermes-agent's schema. Creates tight coupling that makes schema migrations dangerous.
- **Rejected.**

### Session list — Option B: hermes-agent exposes list endpoint, workflow-backend proxies — chosen
Add `GET /api/v5/sessions` to hermes-agent gateway. workflow-backend proxies it, same pattern as `create_session`.

- **Pro:** consistent with existing proxy pattern. hermes-agent owns its own DB. Schema changes in hermes-agent don't touch workflow-backend.
- **Con:** one extra hop.
- **Chosen.**

### workflow_get_tasks — Option A: HTTP call to workflow-backend API
Tool calls `GET {WORKFLOW_BACKEND_URL}/api/workspaces/:wid/features/:fid/tasks`.

- **Con:** circular dependency (hermes-agent → workflow-backend → hermes-agent for chat). At runtime these are two separate services so it technically works, but the coupling is undesirable and fragile under restarts.
- **Rejected.** (Per product spec explicit decision.)

### workflow_get_tasks — Option B: direct psycopg query on workspace DB — chosen
Same `WORKFLOW_DATABASE_URL` already used by `workflow_plugin/db.py`. Add a `get_feature_tasks` function alongside `get_feature_detail`.

- **Pro:** no new env var, no inter-service coupling, same synchronous psycopg pattern already in place.
- **Chosen.**

> **Transport correction (verified against the actual services).** Both target services
> expose the **stateful MCP SSE transport** — `GET /sse` to open the event stream plus
> `POST /messages/` to send — *not* a plain JSON-RPC `POST /`. Confirmed by reading:
> - `git-nexus/services/gitnexus_server/server.py` — routes are `/health`, `/sse` (GET),
>   `Mount("/messages/")`. **SSE-only.** It is a generic passthrough that proxies
>   `list_tools` / `call_tool(name, arguments)` to an underlying `npx gitnexus mcp` stdio
>   subprocess. There is **no** plain REST query endpoint.
> - `rag-service/services/rag_server/server.py` — exposes the MCP tool `rag_query` over
>   `/sse` **and** a plain `POST /query` REST endpoint (`{query, workspace_id, top_k,
>   source_types}` → `{results:[...]}`).
>
> A naive `requests.post(json={"jsonrpc":...})` against an SSE-transport server does not
> work — it requires the MCP handshake (open SSE → `initialize` → `initialized` →
> `tools/call`). The options below reflect this reality.

### GitNexus / RAG tools — Option A: plain `requests.post` JSON-RPC — rejected (factually wrong)
The original draft assumed a stateless JSON-RPC POST endpoint. **Rejected** — git-nexus is
SSE-only and rejects non-handshake POSTs; rag-service's MCP tool is likewise SSE-only (its
only stateless surface is the bespoke `/query` REST route, which git-nexus does not mirror).

### GitNexus / RAG tools — Option B: mixed (rag via `/query` REST, gitnexus via MCP SSE) — rejected
Use rag-service's plain `POST /query` and an MCP SSE client only for git-nexus.

- **Pro:** avoids the MCP client for the rag path.
- **Con:** two different transports for two near-identical "query an index" tools —
  inconsistent handler shape, two error models, harder to test. The rag REST route also
  returns a different envelope (`{results}`) than the MCP tool result, so the agent sees
  two shapes. **Rejected** for inconsistency.

### GitNexus / RAG tools — Option C: uniform MCP SSE client for both — chosen
Use the `mcp` Python package's `ClientSession` over `sse_client(GITNEXUS_MCP_URL)` /
`sse_client(RAG_MCP_URL)`. Register both handlers as **async** (`is_async=True`); the
registry bridges sync→async automatically via `model_tools._run_async` (verified — it is
"the single source of truth for sync->async bridging in tool handlers" and explicitly
handles being called from the gateway's worker thread). Each tool is gated by a
`check_fn` that returns `False` when its URL env var is unset, so `get_definitions`
omits it from the tool list entirely (verified in `tools/registry.py:get_definitions` —
tools whose `check_fn()` is False are filtered out, matching the spec's "silently
omitted").

- **Pro:** one transport, one handler shape, matches the product spec's "MCP" language,
  correctly handles git-nexus being SSE-only, stays entirely within hermes-agent (one
  repo per task preserved — no git-nexus REST endpoint to add).
- **Con:** adds `mcp==1.26.0` to the gateway runtime (today it is in hermes-agent's
  optional extras only, not the `workflow-gateway` extra). Low-risk: pinned version
  already vendored; in-repo precedent exists (`tools/mcp_tool.py`).
- **Chosen.**

### Three-panel layout — Option A: CSS Grid
Replace `flex` container with `grid-cols-[auto_1fr_auto]`.

- **Con:** collapse animation is harder with grid; tracked min/max column widths interact poorly with content overflow.
- **Rejected.**

### Three-panel layout — Option B: Flex + transition-[width] — chosen
Keep the existing `flex min-h-0 flex-1 overflow-hidden` container. Add left panel as a new flex child with `transition-[width] duration-200 overflow-hidden`. Collapse = `w-0`, expanded = `w-64`. Right panel already `w-96`; same pattern.

- **Pro:** consistent with existing layout idioms in the codebase. Easy to animate, overflow-safe.
- **Chosen.**

---

## 4. Chosen Design

### 4.1 hermes-agent: session list endpoint (T1)

**New store function** in `workflow_gateway/db/store.py`:

```python
async def list_sessions(
    db: AsyncSession,
    workspace_id: str,
    feature_id: str,
    limit: int = 50,
) -> list[dict]:
    result = await db.execute(
        select(
            Session.id,
            Session.title,
            Session.started_at,
            Session.last_active_at,
        )
        .where(
            Session.workspace_id == workspace_id,
            Session.feature_id == feature_id,
            Session.archived == False,
        )
        .order_by(Session.last_active_at.desc())
        .limit(limit)
    )
    rows = result.all()
    # last_message_excerpt: separate query per session (N small selects, max 50)
    out = []
    for row in rows:
        excerpt = await _last_assistant_excerpt(db, row.id)
        out.append({
            "id": row.id,
            "title": row.title or "(untitled)",
            "started_at": row.started_at,
            "last_active_at": row.last_active_at,
            "last_message_excerpt": excerpt,
        })
    return out
```

`_last_assistant_excerpt` — selects `content[:120]` from the last active `assistant` message in the session.

**New route** in `workflow_gateway/api/router.py`:

```
GET /api/v5/sessions?workspace_id=X&feature_id=Y[&limit=N]
  → Returns: { "sessions": [{id, title, started_at, last_active_at, last_message_excerpt}] }
```

**Auto-title on first message** — when `stream_chat` is called and the session's `title` is `NULL`, set `title = message[:60]` before starting the agent run. Uses existing `set_session_title` in `store.py`.

---

### 4.2 workflow-backend: session list proxy (T2)

Add `ListSessions` method to `ChatProxyHandler` in `internal/handler/chat_proxy.go`:

```go
// GET /workspaces/:wid/features/:fid/chat/sessions
func (h *ChatProxyHandler) ListSessions(c *gin.Context) {
    workspaceID := c.Param("workspaceId")
    featureID   := c.Param("featureId")
    target := fmt.Sprintf(
        "%s/api/v5/sessions?workspace_id=%s&feature_id=%s",
        h.hermesBaseURL,
        url.QueryEscape(workspaceID),
        url.QueryEscape(featureID),
    )
    req, _ := http.NewRequestWithContext(c.Request.Context(), http.MethodGet, target, nil)
    if auth := c.GetHeader("Authorization"); auth != "" {
        req.Header.Set("Authorization", auth)
    }
    resp, err := h.httpClient.Do(req)
    // ... read body, forward status+body unchanged
}
```

Register in `RegisterChatRoutes`:
```go
rg.GET("/workspaces/:workspaceId/features/:featureId/chat/sessions", h.ListSessions)
```

---

### 4.3 hermes-agent: workflow_plugin context tools (T3)

**New file: `workflow_plugin/tools/tasks.py`**

```python
SCHEMA = {
    "type": "object",
    "properties": {
        "workspace_id": {"type": "string"},
        "feature_id": {"type": "string"},
    },
    "required": ["workspace_id", "feature_id"],
    "additionalProperties": False,
}

def handle(workspace_id: str, feature_id: str, **_) -> dict:
    from ..db import get_feature_tasks
    try:
        return {"ok": True, "tasks": get_feature_tasks(workspace_id, feature_id)}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
```

**New `get_feature_tasks` in `workflow_plugin/db.py`** — psycopg query on `workspace_tasks`:

```python
def get_feature_tasks(workspace_id: str, feature_id: str) -> list[dict]:
    with _conn() as conn:
        rows = conn.execute(
            """
            SELECT t.task_name, t.title, t.status, t.blocked_reason,
                   t.depends_on, t.pr, t.execution
            FROM workspace_tasks t
            JOIN workspace_features f ON f.id = t.feature_id
            JOIN workspaces w ON w.id = f.workspace_id
            WHERE (w.slug = %s OR w.id::text = %s)
              AND (f.feature_name = %s OR f.feature_id::text = %s)
            ORDER BY t.task_name
            """,
            (workspace_id, workspace_id, feature_id, feature_id),
        ).fetchall()
    return [dict(r) for r in rows]
```

**MCP SSE client helper — `workflow_plugin/mcp_client.py`**

Shared async helper both MCP tools use. Connects over SSE, runs the handshake, calls one
tool, returns its result content. Self-contained so the tool handlers stay thin:

```python
from mcp import ClientSession
from mcp.client.sse import sse_client

async def call_mcp_tool(base_url: str, tool: str, arguments: dict) -> list[dict]:
    # base_url is the service's SSE endpoint, e.g. http://gitnexus:8002/sse
    async with sse_client(base_url) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool, arguments)
            # result.content is a list of TextContent/EmbeddedResource; callers
            # extract .text or structured payloads as needed.
            return [_content_to_dict(c) for c in result.content]
```

**New file: `workflow_plugin/tools/gitnexus.py`** — async handler, `is_async=True`.

git-nexus is a generic MCP passthrough; T3 should call `session.list_tools()` once to
confirm the exact tool names + schemas exposed by `npx gitnexus mcp` (per the CLAUDE.md
GitNexus rule these are `query`, `context`, `impact`, `detect_changes`, `list_repos`,
`group_query`). v2 exposes a single passthrough with a `tool` selector defaulting to
`query`:

```python
import os
from ..mcp_client import call_mcp_tool

SCHEMA = {
    "type": "object",
    "properties": {
        "query": {"type": "string", "description": "Natural-language or structured query."},
        "tool":  {"type": "string", "default": "query",
                  "description": "GitNexus tool: query | context | impact | ..."},
    },
    "required": ["query"],
    "additionalProperties": False,
}

def check_available(**_) -> bool:
    return bool(os.environ.get("GITNEXUS_MCP_URL", "").strip())

async def handle(query: str, tool: str = "query", **_) -> dict:
    url = os.environ["GITNEXUS_MCP_URL"]
    try:
        return {"ok": True, "results": await call_mcp_tool(url, tool, {"query": query})}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
```

**New file: `workflow_plugin/tools/rag.py`** — async handler, `is_async=True`.

Calls rag-service's `rag_query` MCP tool. **`workspace_id` is required** — rag-service
rejects queries without it (verified in `_rag_query`). The agent already passes
`workspace_id` to the other workflow tools, so it is a required schema field here too:

```python
import os
from ..mcp_client import call_mcp_tool

SCHEMA = {
    "type": "object",
    "properties": {
        "query":        {"type": "string"},
        "workspace_id": {"type": "string"},
        "top_k":        {"type": "integer", "default": 5},
    },
    "required": ["query", "workspace_id"],
    "additionalProperties": False,
}

def check_available(**_) -> bool:
    return bool(os.environ.get("RAG_MCP_URL", "").strip())

async def handle(query: str, workspace_id: str, top_k: int = 5, **_) -> dict:
    url = os.environ["RAG_MCP_URL"]
    try:
        results = await call_mcp_tool(url, "rag_query",
                                      {"query": query, "workspace_id": workspace_id, "top_k": top_k})
        return {"ok": True, "results": results}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
```

**Updated `workflow_plugin/__init__.py`** — the current loop unpacks **3-tuples**
(`for name, schema, handler in _TOOLS`) and applies `check_fn=check_workflow_available`
to every tool. That breaks the moment a tool needs a *different* `check_fn` or
`is_async=True`. Restructure `_TOOLS` to dict entries carrying optional `check_fn` /
`is_async`:

```python
from .tools import workspace, feature, artifacts, tasks as tasks_tool, gitnexus, rag

_TOOLS = (
    {"name": "workflow_get_workspace_context",  "schema": workspace.SCHEMA,            "handler": workspace.handle,                    "check_fn": check_workflow_available},
    {"name": "workflow_get_feature_state",      "schema": feature.SCHEMA,              "handler": feature.handle,                      "check_fn": check_workflow_available},
    {"name": "workflow_write_product_spec",     "schema": artifacts.WRITE_SPEC_SCHEMA, "handler": artifacts.handle_write_product_spec, "check_fn": check_workflow_available},
    {"name": "workflow_write_technical_design", "schema": artifacts.WRITE_TD_SCHEMA,   "handler": artifacts.handle_write_technical_design, "check_fn": check_workflow_available},
    {"name": "workflow_get_tasks",              "schema": tasks_tool.SCHEMA,           "handler": tasks_tool.handle,                   "check_fn": check_workflow_available},
    {"name": "workflow_query_gitnexus",         "schema": gitnexus.SCHEMA,             "handler": gitnexus.handle, "check_fn": gitnexus.check_available, "is_async": True},
    {"name": "workflow_query_rag",              "schema": rag.SCHEMA,                  "handler": rag.handle,      "check_fn": rag.check_available,      "is_async": True},
)

def register(ctx):
    for t in _TOOLS:
        ctx.register_tool(
            name=t["name"], toolset="workflow", schema=t["schema"], handler=t["handler"],
            check_fn=t.get("check_fn"), is_async=t.get("is_async", False),
        )
    ctx.register_hook("pre_llm_call", inject_context)
```

**Dependency:** add `mcp==1.26.0` to the `workflow-gateway` extra in hermes-agent
`pyproject.toml` (line ~130). It is currently only in the `dev` / `mcp` / `computer-use`
extras, none of which the gateway Dockerfile installs (`uv pip install -e
".[workflow-gateway]"`).

**Updated `workflow_plugin/hooks.py`** — `inject_context` adds a task summary block:

```python
if feature_id and check_workflow_available():
    from .tools.tasks import handle as get_tasks
    result = get_tasks(workspace_id=workspace_id, feature_id=feature_id)
    if result.get("ok"):
        t_list = result["tasks"]
        by_status = {}
        blocked = []
        for t in t_list:
            by_status[t["status"]] = by_status.get(t["status"], 0) + 1
            if t["status"] == "blocked" and t.get("blocked_reason"):
                blocked.append(f"  {t['task_name']}: {t['blocked_reason']}")
        summary = "task_counts: " + ", ".join(f"{k}={v}" for k, v in by_status.items())
        parts.append(summary)
        if blocked:
            parts.append("blocked_tasks:\n" + "\n".join(blocked))
```

---

### 4.4 digital-factory-ui: three-panel layout + FeatureStatusPanel (T4)

**New `src/features/feature-status/FeatureStatusPanel.tsx`**

Uses existing:
- `getFeature(workspaceId, featureId)` → feature stage badge
- `searchFeatureTasks(workspaceId, featureId)` → task list with status icons

Status icon map: `done` = ✓ green, `in_progress` = ● blue, `in_review` / `reviewing` = ◌ blue, `blocked` = ⊗ red, `ready` = → yellow, `todo` = ○ gray.

Panel is read-only. No click-through on tasks in v2.

**Modified `FeatureSessionPage.tsx`**

```tsx
const [leftCollapsed, setLeftCollapsed] = useLocalStorage("df-left-panel-collapsed", false);
const [rightCollapsed, setRightCollapsed] = useLocalStorage("df-right-panel-collapsed", false);

// Auto-collapse left below 1200px
useEffect(() => {
  const mq = window.matchMedia("(max-width: 1199px)");
  const handler = (e: MediaQueryListEvent) => { if (e.matches) setLeftCollapsed(true); };
  mq.addEventListener("change", handler);
  return () => mq.removeEventListener("change", handler);
}, [setLeftCollapsed]);

return (
  <WorkspaceSessionShell workspace={activeWorkspace}>
    <div className="flex min-h-0 flex-1 overflow-hidden">

      {/* Left panel */}
      <div className={cn(
        "shrink-0 overflow-hidden border-r border-border transition-[width] duration-200",
        leftCollapsed ? "w-0" : "w-64",
      )}>
        <FeatureStatusPanel workspaceId={workspaceId} featureId={featureId} />
      </div>

      {/* Left collapse toggle */}
      <CollapseToggle side="left" collapsed={leftCollapsed} onToggle={() => setLeftCollapsed(v => !v)} />

      {/* Center */}
      <div className="min-w-0 flex-1 overflow-hidden">
        <FeatureTabView workspaceId={workspaceId} featureId={featureId} />
      </div>

      {/* Right collapse toggle */}
      <CollapseToggle side="right" collapsed={rightCollapsed} onToggle={() => setRightCollapsed(v => !v)} />

      {/* Right panel */}
      <div className={cn(
        "shrink-0 overflow-hidden border-l border-border transition-[width] duration-200",
        rightCollapsed ? "w-0" : "w-96",
      )}>
        <AgentChatPanel
          workspaceId={workspaceId}
          featureId={featureId}
          onArtifactSaved={handleArtifactSaved}
        />
      </div>

    </div>
  </WorkspaceSessionShell>
);
```

`CollapseToggle` — a thin (`w-3`) click target with a chevron icon, absolutely positioned on the inner edge of each panel.

`useLocalStorage` — thin hook wrapping `localStorage.getItem/setItem` with JSON serialisation.

---

### 4.5 digital-factory-ui: session history + AgentChatPanel refactor (T5)

**New `listChatSessions()` in `chat.ts`**

```ts
export type ChatSessionSummary = {
  id: string;
  title: string;
  started_at: number;
  last_active_at: number;
  last_message_excerpt: string;
};

export async function listChatSessions(
  workspaceId: string,
  featureId: string,
): Promise<ChatSessionSummary[]> {
  const res = await fetch(
    `${getApiBase()}/api/workspaces/${workspaceId}/features/${featureId}/chat/sessions`,
    { credentials: "include" },
  );
  if (!res.ok) throw new Error(`listChatSessions failed (${res.status})`);
  const body = await res.json() as { sessions: ChatSessionSummary[] };
  return body.sessions;
}
```

**New `src/features/agent-chat/SessionHistoryList.tsx`**

- Accepts `sessions: ChatSessionSummary[]`, `loading: boolean`, `onSelect: (id: string) => void`.
- Renders a scrollable list of session rows: title (bold), relative date, excerpt (truncated, muted).
- Empty state: "No conversations yet."

**Refactored `AgentChatPanel.tsx`**

State machine:

```ts
type PanelMode =
  | { mode: "history" }
  | { mode: "active"; sessionId: string };
```

Lifecycle:
- On mount: `mode = history`, `listChatSessions()` called.
- User selects session → `mode = active` with that `sessionId`. Message history loaded from the existing `streamChatTurn` (which sends `session_id` — the hermes-agent already loads history from the DB on `stream_chat`).
- User submits from history mode → `createChatSession()` → `mode = active` with new `session_id`.
- Back button → `mode = history`, re-fetch sessions list.

Header:
- History mode: `"Agent"` title + (future: filter/search placeholder).
- Active mode: back arrow + session title.

The existing `streamChatTurn` and `onArtifactSaved` logic is unchanged — it is moved into the `active` mode render path.

**Removing the on-mount session creation** — `AgentChatPanel` no longer calls `createChatSession` on mount. Sessions are created lazily on first user message submission. This eliminates the orphan session problem (sessions created but never used when user opens a feature and doesn't chat).

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| `workflow_plugin/db.py` uses `psycopg` for sync workspace DB reads | Existing | ✅ Live (`db.py` already queries `workspace_tasks` parent tables) | No — `workspace_tasks` query is additive |
| `workspace_tasks` table in workspace DB | Existing schema | ✅ `database/workspace/schema.dbml` v003 — `workspace_tasks` present | No |
| asyncpg / SQLAlchemy async in hermes-agent gateway | Existing | ✅ Used for session store | No |
| `WORKFLOW_DATABASE_URL` env var in hermes-agent | Existing | ✅ Already required by `workflow_plugin/db.py` | No |
| `GITNEXUS_MCP_URL` env var in hermes-agent | New optional | Not yet set anywhere (verified — name not present in any repo). Points at git-nexus **`/sse`** endpoint, e.g. `http://gitnexus:8002/sse` | No — `check_fn` omits the tool from the list when unset |
| `RAG_MCP_URL` env var in hermes-agent | New optional | Not yet set anywhere. Points at rag-service **`/sse`** endpoint | No — `check_fn` omits the tool when unset |
| git-nexus transport | External service | ✅ Verified **SSE-only** (`/health`, `/sse`, `/messages/`) — no plain REST query route. Generic `list_tools`/`call_tool` passthrough to `npx gitnexus mcp` | Drives the MCP-client choice (Option C) |
| rag-service transport | External service | ✅ Verified MCP `rag_query` over `/sse` **and** a plain `POST /query` REST route. `rag_query` **requires `workspace_id`** (rejects empty) | No — tool passes `workspace_id` |
| `mcp==1.26.0` in the **`workflow-gateway`** extra | New runtime dep | ⚠️ `mcp` is pinned in hermes-agent's `dev`/`mcp`/`computer-use` extras only — **not** in `workflow-gateway`, which is what the gateway Dockerfile installs | T3 — add `mcp==1.26.0` to the `workflow-gateway` extra |
| `model_tools._run_async` sync→async bridge | Existing | ✅ Verified — registry auto-bridges `is_async=True` handlers; helper explicitly handles the gateway worker-thread case | No |
| `searchFeatureTasks` in `digital-factory-ui/client.ts` | Existing | ✅ `GET /features/:fid/tasks` exists | No — T4 uses it as-is |
| workflow-backend `ListSessions` proxy → hermes-agent `GET /api/v5/sessions` | New endpoint (T1) | Not yet built | T2 can be written against known contract; needs T1 deployed for e2e |
| `listChatSessions` in `chat.ts` → workflow-backend `GET /chat/sessions` | New endpoint (T2) | Not yet built | T5 is BLOCKED on T2 being deployed |
| Three-panel layout (`FeatureSessionPage`) in place | T4 | Not yet built | T5 should land after T4 to avoid layout merge conflicts |

---

## 6. Parallelization / Blocking Analysis

```
T1: hermes-agent — GET /api/v5/sessions endpoint + auto-title on first message
  └── Can begin now — no blockers

T2: workflow-backend — ListSessions proxy route (GET /chat/sessions)
  └── Can begin now — proxy contract defined above; mock upstream for tests
  └── Needs T1 deployed for full integration test (not a code blocker)

T3: hermes-agent — workflow_plugin: workflow_get_tasks + gitnexus + rag tools + hook update
  └── Can begin now — no blockers
  └── T1 and T3 run in parallel (touch different directories in hermes-agent)

T4: digital-factory-ui — three-panel layout + FeatureStatusPanel + CollapseToggle
  └── Can begin now — uses existing searchFeatureTasks + getFeature APIs

  T1, T2, T3, T4 all run in parallel (Wave 1)

  T5: digital-factory-ui — SessionHistoryList + AgentChatPanel refactor + listChatSessions
      └── BLOCKED on T2 (listChatSessions needs /chat/sessions endpoint live)
      └── BLOCKED on T4 (avoid layout merge conflicts; T4 reshapes FeatureSessionPage
          which imports AgentChatPanel — land T4 first on the feature branch)
```

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `hermes-agent` | T1: `workflow_gateway/api/router.py`, `workflow_gateway/db/store.py` — new `list_sessions`, `_last_assistant_excerpt`, auto-title logic, `GET /api/v5/sessions` route | Session history endpoint |
| `hermes-agent` | T3: new `workflow_plugin/tools/tasks.py`, `workflow_plugin/tools/gitnexus.py`, `workflow_plugin/tools/rag.py`, `workflow_plugin/mcp_client.py`; updates to `workflow_plugin/__init__.py` (dict `_TOOLS` + `register`), `workflow_plugin/db.py` (`get_feature_tasks`), `workflow_plugin/hooks.py`; `pyproject.toml` (`mcp==1.26.0` into `workflow-gateway` extra) | New agent context tools + enriched hook + MCP SSE client |
| `workflow-backend` | T2: `internal/handler/chat_proxy.go` — add `ListSessions`, register `GET` route | Session list proxy |
| `digital-factory-ui` | T4: new `src/features/feature-status/FeatureStatusPanel.tsx`, `CollapseToggle`, `useLocalStorage`; modify `FeatureSessionPage.tsx` | Three-panel layout |
| `digital-factory-ui` | T5: new `src/features/agent-chat/SessionHistoryList.tsx`; modify `AgentChatPanel.tsx`, `src/services/workflow-backend/chat.ts` | Session history UI |
| `management-repo` | `database/hermes-agent/schema.dbml` — annotate new compound index if added | Already done (v2 note in schema) |

---

## 8. Validation and Release Impact

### Testing

**T1 (hermes-agent sessions endpoint)**
- Unit: `test_list_sessions` — seed 3 sessions for a workspace+feature, 1 archived, assert list returns 2 ordered by `last_active_at DESC`.
- Unit: auto-title — call `stream_chat` on a null-title session, assert `title` set to first 60 chars of message.
- Integration: `GET /api/v5/sessions` with real Postgres against `docker-compose` test stack.

**T2 (workflow-backend proxy)**
- Unit: mock hermes-agent returning fixed `{sessions:[...]}`, assert proxy forwards unchanged.
- Assert `workspace_id` and `feature_id` are URL-encoded in the upstream request.

**T3 (workflow_plugin tools)**
- Unit: `workflow_get_tasks` — mock psycopg, assert query uses correct parametrisation.
- Unit: `workflow_query_gitnexus` / `workflow_query_rag` — mock `call_mcp_tool` (or
  `mcp.ClientSession`), assert the right tool name + arguments are passed (`rag_query`
  with `workspace_id`; gitnexus `query` / selected `tool`).
- Unit: `check_available` gating — with `GITNEXUS_MCP_URL` / `RAG_MCP_URL` unset, assert
  `registry.get_definitions({...})` omits the tool from the returned list (not just that
  it errors at call time).
- Unit: `register()` — assert all 7 tools register with the correct `check_fn` and that
  the two MCP tools register with `is_async=True`.
- Unit: `inject_context` hook — seed tasks with one `blocked` entry, assert hook output
  includes `blocked_tasks:` block.

**T4 (layout)**
- Component: `FeatureStatusPanel` renders feature badge + task rows.
- Component: left panel `w-0` when `leftCollapsed=true`.
- Component: collapse toggle calls callback on click.
- E2E smoke: layout visible at 1280px; left panel auto-collapses at 1024px.

**T5 (session history UI)**
- Component: `SessionHistoryList` renders session rows; empty state when `sessions=[]`.
- Component: `AgentChatPanel` in history mode shows `SessionHistoryList`; selecting a session transitions to active mode; back button returns to history.
- Component: submitting from history mode calls `createChatSession` before `streamChatTurn`.
- Integration: `listChatSessions` against mock workflow-backend.

### Migration / Config

- No DB schema changes — `sessions` and `messages` tables unchanged. The new `list_sessions` query uses existing columns.
- New optional env vars in hermes-agent: `GITNEXUS_MCP_URL` and `RAG_MCP_URL`, each
  pointing at the respective service's **`/sse`** endpoint. Add to
  `workflow_gateway/.env.example`.
  - Naming note: CLAUDE.md's rag-context rule references `MCP_RAG_URL` for the *Claude
    Code executor's* `.mcp.json` (a different consumer that surfaces `mcp__rag-server__*`
    tools to the executor). This feature's `RAG_MCP_URL` is hermes-agent's own
    server-to-server URL and is intentionally distinct. Both can coexist; T3 should not
    conflate them.
- New runtime dep: add `mcp==1.26.0` to the **`workflow-gateway`** extra in hermes-agent
  `pyproject.toml` (already vendored at that pin in other extras).
- No workflow-backend DB changes.
- No digital-factory-ui env var changes.

### Rollout

- T1/T2/T3 are additive to hermes-agent and workflow-backend — existing `create_session` / `stream_chat` paths are unchanged.
- T4/T5 modify `FeatureSessionPage` and `AgentChatPanel`. The layout change is a breaking visual change; no feature flag needed since both panels are always rendered (just collapsed by default on narrow screens).
- On-mount session creation removal (T5): orphan sessions will no longer accumulate. Existing sessions in the DB are unaffected.
- If T2 is not yet deployed when T5 ships, `listChatSessions` will return a 404 → `AgentChatPanel` falls back to empty session list + graceful error state. The active chat path is unaffected.

### Backward compatibility

- v1 `AgentChatPanel` API (`workspaceId`, `featureId`, `onArtifactSaved`) is preserved unchanged.
- The `HermesEvent` type union in `chat.ts` is additive.
- All existing workflow-backend routes are unchanged.

## Reference
- v1 technical design: `docs/features/m3-agent-chat/technical-design.md`
- Session store schema: `database/hermes-agent/schema.dbml`
- Workspace DB schema: `database/workspace/schema.dbml` (`workspace_tasks`, `workspace_features`)
- hermes-agent gateway: `hermes-agent/workflow_gateway/`
- hermes-agent plugin: `hermes-agent/workflow_plugin/`
- chat proxy: `workflow-backend/internal/handler/chat_proxy.go`
- chat UI: `digital-factory-ui/src/features/agent-chat/`
- chat client: `digital-factory-ui/src/services/workflow-backend/chat.ts`
