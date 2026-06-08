# m3-agent-chat-v2 — Task Breakdown

**Feature status:** `in_tdd` | **Stage:** `tasks` (awaiting approval)
Machine-readable state lives in `tasks/T<n>.yaml`. This file is narrative only.

## Index

| ID  | Wave | Title                                                          | Depends on |
|-----|------|----------------------------------------------------------------|------------|
| T1  | 1    | hermes-agent: session list endpoint + auto-title               | —          |
| T2  | 1    | workflow-backend: ListSessions proxy route                     | —          |
| T3  | 1    | hermes-agent: workflow_plugin context tools (tasks/gitnexus/rag)| —          |
| T4  | 1    | digital-factory-ui: three-panel layout + FeatureStatusPanel    | —          |
| T5  | 2    | digital-factory-ui: session history + AgentChatPanel refactor  | T2, T4     |

---

## T1 — hermes-agent: session list endpoint + auto-title

### Description
Add a session-listing endpoint to the workflow gateway so the UI can render a session
history list per feature. Implements technical design §4.1.

- New `list_sessions(db, workspace_id, feature_id, limit=50)` and a `_last_assistant_excerpt`
  helper in `workflow_gateway/db/store.py`. Selects non-archived sessions for the
  workspace+feature, newest-first by `last_active_at`, each with a short excerpt of its
  last active assistant message.
- New route `GET /api/v5/sessions?workspace_id=X&feature_id=Y[&limit=N]` in
  `workflow_gateway/api/router.py`, returning `{ "sessions": [...] }`.
- Auto-title: in `stream_chat`, when the session `title` is `NULL`, set it to the first
  60 chars of the incoming message (reuse existing `set_session_title`) before the agent
  run starts.

Touches only `hermes-agent`. No schema changes — uses existing `sessions` / `messages`
columns.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] `store.py`: `list_sessions` — filter `archived == False`, order `last_active_at DESC`, `limit`
- [ ] `store.py`: `_last_assistant_excerpt` — last active `assistant` message `content[:120]`
- [ ] `router.py`: `GET /api/v5/sessions` returning `{sessions: [...]}` (id, title, started_at, last_active_at, last_message_excerpt)
- [ ] `router.py`: auto-title on first message in `stream_chat` when `title` is NULL
- [ ] Unit: 3 sessions seeded (1 archived) → returns 2 ordered by `last_active_at DESC`
- [ ] Unit: auto-title sets `title` to first 60 chars on a null-title session
- [ ] Integration: `GET /api/v5/sessions` against the docker-compose test Postgres

---

## T2 — workflow-backend: ListSessions proxy route

### Description
Add a transparent proxy route so the browser reaches the new hermes-agent session-list
endpoint through workflow-backend (the browser never talks to hermes-agent directly).
Implements technical design §4.2.

- New `ListSessions` method on `ChatProxyHandler` in `internal/handler/chat_proxy.go`:
  `GET /workspaces/:workspaceId/features/:featureId/chat/sessions` → proxies to
  `GET {hermesBaseURL}/api/v5/sessions?workspace_id=…&feature_id=…` with URL-encoded
  query params, forwards the `Authorization` header, and returns the upstream status +
  body unchanged.
- Register the route in `RegisterChatRoutes`.

Touches only `workflow-backend`. Can be written and unit-tested against the contract with
a mock upstream; full e2e needs T1 deployed (not a code blocker).

### Required skills
- go-best-practices
- backend-engineer

### Subtasks
- [ ] `chat_proxy.go`: `ListSessions` handler — build upstream URL with `url.QueryEscape` on workspace/feature
- [ ] Forward `Authorization` header; return upstream status + body unchanged
- [ ] Register `GET .../chat/sessions` in `RegisterChatRoutes`
- [ ] Unit: mock upstream returns fixed `{sessions:[...]}` → proxy forwards unchanged
- [ ] Unit: assert workspace_id / feature_id are URL-encoded in the upstream request
- [ ] `golangci-lint run` clean

---

## T3 — hermes-agent: workflow_plugin context tools (tasks/gitnexus/rag)

### Description
Give the agent live, grounded context. Implements technical design §4.3.

- New `workflow_plugin/tools/tasks.py` — `workflow_get_tasks` tool; new `get_feature_tasks`
  in `workflow_plugin/db.py` (direct psycopg read of `workspace_tasks` via the existing
  `WORKFLOW_DATABASE_URL`, no workflow-backend call).
- New `workflow_plugin/mcp_client.py` — shared async `call_mcp_tool(base_url, tool, args)`
  using `mcp.ClientSession` over `sse_client`.
- New `workflow_plugin/tools/gitnexus.py` and `workflow_plugin/tools/rag.py` — async
  handlers (`is_async=True`) gated by `check_available` on `GITNEXUS_MCP_URL` /
  `RAG_MCP_URL`. Each carries a tool-level `description`.
- Restructure `_TOOLS` in `workflow_plugin/__init__.py` to dict entries (the 3-tuple
  unpacking breaks with per-tool `check_fn` / `is_async`); update `register()`.
- Update `workflow_plugin/hooks.py` `inject_context` to add a live task-summary block and
  advertise the available lookup tools (list built from the same `check_fn` results).
- Add `mcp==1.26.0` to the `workflow-gateway` extra in `pyproject.toml`.

Touches only `hermes-agent` (`workflow_plugin/` + `pyproject.toml`). Independent of T1
(different directory; no file overlap). T3 should call `session.list_tools()` once to
confirm the exact GitNexus tool names/schemas exposed by `npx gitnexus mcp`.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] `db.py`: `get_feature_tasks(workspace_id, feature_id)` — psycopg query on `workspace_tasks` joined to features/workspaces
- [ ] `tools/tasks.py`: `workflow_get_tasks` with tool-level description + `check_workflow_available`
- [ ] `mcp_client.py`: `call_mcp_tool(base_url, tool, args)` over `sse_client` + `ClientSession`
- [ ] `tools/gitnexus.py`: async handler + `check_available(GITNEXUS_MCP_URL)`; confirm tool names via `list_tools()`
- [ ] `tools/rag.py`: async handler + `check_available(RAG_MCP_URL)`; pass required `workspace_id`
- [ ] `__init__.py`: dict `_TOOLS` + `register()` passing `check_fn` / `is_async`
- [ ] `hooks.py`: task-summary block + capability advertisement in the instruction line
- [ ] `pyproject.toml`: add `mcp==1.26.0` to the `workflow-gateway` extra
- [ ] Unit: `workflow_get_tasks` parametrisation; gitnexus/rag arg passing (mock `call_mcp_tool`)
- [ ] Unit: `check_available` gating — tool omitted from `registry.get_definitions` when URL unset
- [ ] Unit: `register()` registers 7 tools; the 2 MCP tools register `is_async=True`
- [ ] Unit: `inject_context` includes `blocked_tasks:` block when a task is blocked

---

## T4 — digital-factory-ui: three-panel layout + FeatureStatusPanel

### Description
Reshape the feature view into the IDE-style three-panel layout. Implements technical
design §4.4.

- New `src/features/feature-status/FeatureStatusPanel.tsx` — read-only left panel: feature
  stage badge (from existing `getFeature`) + ordered task list with status icons (from
  existing `searchFeatureTasks`). No click-through in v2.
- New `CollapseToggle` component and a `useLocalStorage` hook.
- Modify `FeatureSessionPage.tsx` — flex shell: collapsible left panel (`w-64` / `w-0`,
  `transition-[width]`), unchanged center `FeatureTabView`, collapsible right
  `AgentChatPanel` (`w-96`). Left auto-collapses below 1200px; collapse state persisted in
  `localStorage`.

Touches only `digital-factory-ui`. Uses existing task/feature APIs — no new client method.
The `AgentChatPanel` props (`workspaceId`, `featureId`, `onArtifactSaved`) are preserved so
T5 can refactor its internals without a layout merge conflict.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices

### Subtasks
- [ ] `useLocalStorage` hook (JSON-serialised get/set)
- [ ] `CollapseToggle` — thin edge click target with chevron, `side` + `collapsed` + `onToggle` props
- [ ] `FeatureStatusPanel` — stage badge + task rows with status icon map (done/in_progress/blocked/ready/todo)
- [ ] `FeatureSessionPage`: flex shell with left (`w-64`/`w-0`) + center (`flex-1`) + right (`w-96`/`w-0`)
- [ ] Auto-collapse left below 1200px via `matchMedia`; persist both collapse flags in `localStorage`
- [ ] Component test: `FeatureStatusPanel` renders badge + task rows
- [ ] Component test: left panel is `w-0` when collapsed; toggle fires callback
- [ ] Test suite + lint clean

---

## T5 — digital-factory-ui: session history + AgentChatPanel refactor

### Description
Surface the session history list and add back-navigation. Implements technical design §4.5.

- Add `listChatSessions(workspaceId, featureId)` + `ChatSessionSummary` type to
  `src/services/workflow-backend/chat.ts`.
- New `src/features/agent-chat/SessionHistoryList.tsx` — scrollable list of session rows
  (title, relative date, excerpt) with empty state; `onSelect` callback.
- Refactor `AgentChatPanel.tsx` into a `history ↔ active` state machine. History mode shows
  `SessionHistoryList` + input (submitting creates a new session via `createChatSession`
  then enters active mode). Active mode shows the message thread + a back arrow + session
  title; the existing `streamChatTurn` / `onArtifactSaved` logic moves into the active
  render path. Remove on-mount `createChatSession` (sessions created lazily — no orphans).

Touches only `digital-factory-ui`.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] `chat.ts`: `listChatSessions` + `ChatSessionSummary` type (GET `.../chat/sessions`)
- [ ] `SessionHistoryList.tsx`: rows (title/date/excerpt) + "No conversations yet." empty state
- [ ] `AgentChatPanel`: `PanelMode` state machine (`history` ↔ `active`)
- [ ] History submit → `createChatSession` → active mode with new session_id
- [ ] Session select → active mode loads that session (history replayed via `stream_chat`)
- [ ] Back arrow → history mode + re-fetch sessions list
- [ ] Remove on-mount session creation; graceful empty/error state if `listChatSessions` 404s
- [ ] Component test: history shows list; select → active; back → history
- [ ] Component test: submit from history calls `createChatSession` before `streamChatTurn`
- [ ] Test suite + lint clean

---

## Wave summary

- **Wave 1 (parallel, no blockers):** T1, T2, T3, T4.
- **Wave 2:** T5 — blocked on T2 (`/chat/sessions` endpoint must be live for `listChatSessions`)
  and T4 (T4 reshapes `FeatureSessionPage`, which hosts `AgentChatPanel`; land T4 first to
  avoid a layout merge conflict).
