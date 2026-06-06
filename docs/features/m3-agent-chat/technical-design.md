# Technical Design

## Feature
- Feature ID: `m3-agent-chat`
- Title: Agent Chat — Conversational Interface for Feature Authoring

---

## 1. Current State

### digital-factory-ui
- Next.js 16.2 (App Router), React 19, TailwindCSS 4, HeroUI v3.
- `FeatureSessionPage` renders `WorkspaceSessionShell` (header) → `FeatureTabView`
  (tabs: Product Spec / Technical Design / Tasks / Logs).
- `WorkspaceSessionShell` children area: `flex min-h-0 flex-1 flex-col overflow-hidden` —
  full-height column, no horizontal split.
- API calls: thin `fetch`-based `request<T>()` in `src/services/workflow-backend/client.ts`;
  all calls target `NEXT_PUBLIC_WORKFLOW_API_URL`. **No SSE or streaming client exists.**
- `@microsoft/fetch-event-source` is not in the dep tree.
- **No chat UI components.** Voyager's `voyager-interface` has production-ready primitives
  (`Conversation`, `MessageThread`, `Message`, `PromptInput`, `Loader`) on the same
  HeroUI + TailwindCSS stack — directly portable.

### workflow-backend
- Go 1.25, Gin, PostgreSQL (pgx v5). All routes return synchronous JSON.
- `gin-contrib/sse v1.1.1` is an indirect dep (via Gin) — unused today.
- **workflow-backend's mission includes forwarding the agent stream to the frontend.**
  New proxy endpoints will be added that pipe hermes-agent SSE bytes transparently to
  the browser. `HERMES_AGENT_URL` lives in workflow-backend — never in the browser env.

### hermes-agent (forked — `/Users/pye/code/voyager/hermes-agent`)
The team has forked NousResearch's Hermes agent. Key characteristics of the base:
- **`run_agent.py:AIAgent`** — the agent core: LLM loop, tool dispatch, session
  management, context compression.
- **Plugin system** (`hermes_cli/plugins.py`): scans 4 locations at startup; each plugin
  exposes `register(ctx)`; `ctx.register_tool()` adds tools; 27 lifecycle hooks available
  (`pre_llm_call`, `post_tool_call`, `on_session_end`, etc.).
- **18+ bundled plugins**: disk-cleanup, memory, browser, platforms (Telegram/Discord/…),
  model-providers, etc.
- **Web server** (`hermes_cli/web_server.py`): FastAPI on `localhost:9119` — designed for
  single-user, local use. Streaming via WebSocket (`/api/pty`, `/api/ws`).
- **Persistence**: SQLite (`~/.hermes/state.db`) with sessions + messages + FTS5.
  Per-session metadata, full message history, compression locks.
- **20+ LLM providers** including Anthropic (`anthropic==0.86.0` optional dep).
- **Not multi-tenant by default.** Single-user SQLite and localhost binding need a
  gateway layer for workspace-scoped, multi-user deployment.

### swell-hermes (integration reference — `/Users/pye/code/voyager/swell-hermes`)
Demonstrates exactly how to wrap the Hermes fork for production multi-user use:
- **Gateway pattern**: FastAPI service (`gateway/`) that imports Hermes as an in-process
  library via `AIAgent`. Handles auth (JWT), billing (credits), sessions (Postgres via
  asyncpg), SSE event translation, human-in-loop approval.
- **Plugin**: `voyager_plugin/` with `register(ctx)` — adds trading tools.
- **Session ownership**: gateway owns Postgres tables (`voyager_sessions_v4`,
  `voyager_messages_v4`); Hermes is given `session_db=NoOpSessionDB()` so it doesn't
  write to its own SQLite.
- **SSE envelope** (`gateway/streaming/`): translates Hermes callback events to the
  exact same `data: {json}\n\n` shape that voyager-interface already speaks:
  `message_output_partial`, `tool_call_item`, `function_call_output`, `usage`,
  `error`, `ignored`, `[DONE]`.

---

## 2. Problem Framing

### What needs to change
1. The **hermes-agent fork** needs two additions: a `workflow_gateway/` module (FastAPI,
   swell-hermes pattern) and a `workflow_plugin/` (4 tools for reading and writing
   workspace artifacts). Together these turn the fork into a deployable service.
2. **workflow-backend** gains transparent SSE proxy endpoints: the browser never reaches
   hermes-agent directly; `HERMES_AGENT_URL` is server-side only.
3. The **feature view layout** gains a fixed right-side chat panel (horizontal split
   in `FeatureSessionPage`).
4. The **frontend** manages sessions via workflow-backend proxy routes and consumes the
   forwarded SSE stream using `@microsoft/fetch-event-source`.
5. An `artifact_saved` SSE event triggers document panel refresh.

### What must remain stable
- All existing `FeatureTabView` panels and workflow-backend routes — purely additive.
- The workflow lifecycle gates — agent drafts; human approves via `/approve-feature`.
- The voyager SSE event envelope — same shape, same client code.
- The hermes-agent fork's existing code — additions only (gateway module + plugin).

### Fixed assumptions
- Hermes uses `claude-sonnet-4-6` (matches `workspace.yaml → model_policy.implementation.default`).
- `ANTHROPIC_API_KEY` and `GITHUB_TOKEN` live in hermes-agent's environment.
- Session persistence: Postgres (asyncpg) owned by the gateway, not Hermes SQLite.
- The frontend never reaches hermes-agent directly; all traffic routes through
  workflow-backend proxy endpoints.
- `workspace_id` and `feature_id` are forwarded from the browser → workflow-backend →
  hermes-agent with every `stream_chat` request.

---

## 3. Options Considered

### Option A — Use hermes-agent's built-in web server directly
Connect workflow-backend proxy to `localhost:9119`. Use hermes-agent's existing
WebSocket `/api/pty` for streaming.

- **Rejected.** Built for single-user local use (SQLite, localhost). No workspace
  scoping, no multi-tenant session model, WebSocket shape mismatches the expected SSE
  envelope. Would require significant monkey-patching of the fork's internals.

### Option B — hermes-agent fork + workflow_gateway + workflow_plugin — chosen
Add a `workflow_gateway/` module (swell-hermes pattern) and `workflow_plugin/` directly
to the fork. The gateway uses `AIAgent` as a library, owns Postgres sessions, translates
to the SSE envelope. workflow-backend proxies to the gateway's HTTP API.

- **Chosen.** Follows the proven swell-hermes integration path exactly. The fork is the
  canonical M2 deployment artifact — we extend it rather than wrap it externally. The
  plugin system is the right extension point for domain tools.

### Option C — Build a separate Python service from scratch
- **Rejected.** Duplicates work already done in swell-hermes and the hermes-agent fork.

---

## 4. Chosen Design

### 4.1 Additions to hermes-agent fork

Two new top-level directories added to the fork (no modifications to existing code):

```
hermes-agent/                         ← existing fork (untouched)
├── run_agent.py                       ← AIAgent class
├── hermes_cli/                        ← plugin loader, web server, etc.
├── plugins/                           ← existing bundled plugins
│   └── ...
│
├── workflow_gateway/                  ← NEW — FastAPI gateway (swell-hermes pattern)
│   ├── app.py                         ← FastAPI factory (prefix: /api/v5)
│   ├── api/
│   │   └── router.py                  ← /create_session, /stream_chat routes
│   ├── sessions/
│   │   └── __init__.py                ← asyncpg Postgres session + message store
│   ├── streaming/
│   │   └── __init__.py                ← Hermes callbacks → SSE event envelope
│   ├── auth/
│   │   └── __init__.py                ← JWT verify (stub for v1 — no Privy/credits)
│   └── approval/
│       └── __init__.py                ← human-in-loop registry (stub for v1)
│
└── workflow_plugin/                   ← NEW — domain tools as a Hermes plugin
    ├── __init__.py                    ← register(ctx) entry point
    ├── tools.py                       ← tool schemas + handlers
    ├── client.py                      ← WorkflowClient (HTTP to workflow-backend)
    └── plugin.yaml                    ← manifest: name: workflow
```

**workflow_gateway/app.py** (entry point):
```python
from fastapi import FastAPI
from run_agent import AIAgent
from workflow_gateway.api import router

def create_app() -> FastAPI:
    app = FastAPI(title="hermes workflow gateway")
    app.include_router(router, prefix="/api/v5")
    return app

app = create_app()
# Start: uvicorn workflow_gateway.app:app --host 0.0.0.0 --port 8000
```

**API contract** (same shape as swell-hermes / voyager_agent v5):

```
POST /api/v5/create_session
  Body:    { "user_id": "<string>" }
  Returns: { "session_id": "sess_<hex>" }

POST /api/v5/stream_chat
  Headers: Authorization: Bearer <token>
  Body:    { "session_id": "...", "message": "...",
             "workspace_id": "...", "feature_id": "..." }
  Returns: text/event-stream
```

**SSE event types** — identical envelope to swell-hermes:

| Event | Payload | When |
|---|---|---|
| `message_output_partial` | `{ "content": "<text>" }` | Each streaming text token |
| `tool_call_item` | `{ "call_id": "...", "name": "<tool>", "status": "running" }` | Tool starts |
| `function_call_output` | `{ "call_id": "...", "name": "<tool>", "output": {...} }` | Tool result |
| `artifact_saved` | `{ "artifact": "product_spec" \| "technical_design" }` | Write tool done |
| `usage` | `{ "input": N, "output": N, "cached": N }` | End of turn |
| `error` | `{ "message": "..." }` | Stream error |
| `ignored` | `{ "reason": "session_busy" }` | Concurrent stream blocked |

`artifact_saved` is a new event type emitted by `workflow_gateway/streaming/` after a
write-tool `function_call_output` event.

**workflow_plugin — register(ctx):**
```python
# workflow_plugin/__init__.py
_TOOLS = (
    ("workflow_get_workspace_context", WS_CONTEXT_SCHEMA,   handle_get_workspace_context),
    ("workflow_get_feature_state",     FEATURE_STATE_SCHEMA, handle_get_feature_state),
    ("workflow_write_product_spec",    WRITE_SPEC_SCHEMA,    handle_write_product_spec),
    ("workflow_write_technical_design",WRITE_TD_SCHEMA,      handle_write_technical_design),
)

def _inject_feature_context(messages, **kwargs):
    # pre_llm_call hook: inject workspace + feature state into system context
    ...

def register(ctx):
    for name, schema, handler in _TOOLS:
        ctx.register_tool(name=name, toolset="workflow",
                          schema=schema, handler=handler,
                          check_fn=check_workflow_available)
    ctx.register_hook("pre_llm_call", _inject_feature_context)
```

**workflow_plugin — tools:**

| Tool | Handler | Implementation |
|---|---|---|
| `workflow_get_workspace_context` | `handle_get_workspace_context` | HTTP GET `{WORKFLOW_BACKEND_URL}/api/workspaces/{workspace_id}` |
| `workflow_get_feature_state` | `handle_get_feature_state` | GET feature detail + GitHub Contents API for raw artifact Markdown |
| `workflow_write_product_spec` | `handle_write_product_spec` | GitHub Contents API `PUT /repos/{owner}/{repo}/contents/docs/features/{id}/product-spec.md` |
| `workflow_write_technical_design` | `handle_write_technical_design` | Same, `technical-design.md` |

After `workflow_write_*` succeeds, the streaming layer emits an `artifact_saved` event
before the turn-end `usage` event.

**`pre_llm_call` hook** — injects per-turn context into the system prompt:
- Workspace name, repos list (from `workflow_get_workspace_context`).
- Current feature stage, existing artifact excerpts (from `workflow_get_feature_state`).
- Instruction: *"You draft artifacts through tools. You never advance lifecycle state
  directly. The human approves via the existing approval flow."*

**Hermes config** (`hermes_home/config.yaml`):
```yaml
plugins:
  enabled:
    - workflow
agent:
  model: claude-sonnet-4-6
  provider: anthropic
```

**Session management**: `workflow_gateway/sessions/` uses asyncpg Postgres with the
same schema as swell-hermes (`voyager_sessions_v4`, `voyager_messages_v4`). `AIAgent`
is instantiated with `session_db=NoOpSessionDB()` so Hermes does not write to SQLite.
Each gateway session maps to one `AIAgent` instance with `workspace_id + feature_id`
stored in the session record.

---

### 4.2 workflow-backend SSE proxy

New `ChatProxyHandler` in Go — transparent byte-pipe, no event parsing, no buffering.

**Two new routes** added to the router in `cmd/api/api.go`:

```
POST /api/workspaces/:workspaceId/features/:featureId/chat/session
  → proxies to: POST {HERMES_AGENT_URL}/api/v5/create_session
  → forwards Authorization header

POST /api/workspaces/:workspaceId/features/:featureId/chat
  → proxies to: POST {HERMES_AGENT_URL}/api/v5/stream_chat
  → injects workspace_id + feature_id into forwarded body
  → pipes response bytes back: Content-Type: text/event-stream
  → uses gin's c.Stream() + http.Flusher for byte-pipe
  → promotes gin-contrib/sse from indirect to direct dep
```

New file: `internal/handler/chat_proxy.go`. Isolated `ChatProxyHandler` struct, takes
`hermesBaseURL string` injected at startup from `HERMES_AGENT_URL` env var.

---

### 4.3 Layout change (digital-factory-ui)

Modify `FeatureSessionPage` — horizontal split inside `WorkspaceSessionShell`:

```tsx
<WorkspaceSessionShell workspace={activeWorkspace}>
  <div className="flex min-h-0 flex-1 overflow-hidden">
    <div className="flex-1 min-w-0 overflow-hidden">
      <FeatureTabView workspaceId={workspaceId} featureId={featureId} />
    </div>
    <div className="w-80 shrink-0 border-l border-border flex flex-col">
      <AgentChatPanel
        workspaceId={workspaceId}
        featureId={featureId}
        onArtifactSaved={handleArtifactSaved}
      />
    </div>
  </div>
</WorkspaceSessionShell>
```

Panel width: `w-80` (320 px) fixed for v1.

---

### 4.4 Chat panel UI (digital-factory-ui)

New module: `src/features/agent-chat/`

Port from `voyager-interface/src/components/intelligence/agent/agent-elements/`:
- `Conversation` + `ConversationContent` — scrollable container, scroll-to-bottom button
- `Message` + `MessageContent` — user bubble vs assistant prose
- `MessageThread` — iterates messages, `Loader` while streaming
- `PromptInput` / `PromptInputTextarea` / `PromptInputToolbar` / `PromptInputSubmit`

New component (not in voyager): `SlashCommandPicker` — popover above the input when
the textarea value starts with `/`; filters a static registry in real time; arrow-key +
Enter or click inserts the command name; Escape dismisses.

```ts
const COMMANDS = [
  { name: "/write-product-spec",     hint: "Draft or update the product spec" },
  { name: "/write-technical-design", hint: "Draft or update the technical design" },
  { name: "/get-feature-state",      hint: "Show current feature lifecycle state" },
  { name: "/get-workspace-context",  hint: "Show repos, roles, model policy" },
];
```

`AgentChatPanel` manages session lifecycle (create on mount via `/chat/session`, persist
`session_id` in component state, feed messages + status into `MessageThread`).

---

### 4.5 Hermes API client (digital-factory-ui)

New file: `src/services/workflow-backend/chat.ts`. Uses existing
`NEXT_PUBLIC_WORKFLOW_API_URL` — no new frontend env var.

```ts
createChatSession(workspaceId, featureId, userId): Promise<{ session_id: string }>
// → POST /api/workspaces/:wid/features/:fid/chat/session

streamChatTurn(params, onEvent, onDone, onError): AbortController
// → fetchEventSource POST /api/workspaces/:wid/features/:fid/chat

type HermesEvent =
  | { type: "delta"; text: string }
  | { type: "tool_start"; name: string }
  | { type: "tool_result"; name: string; output: unknown }
  | { type: "artifact_saved"; artifact: "product_spec" | "technical_design" }
  | { type: "error"; message: string }
  | { type: "done" };
```

---

### 4.6 Document refresh on artifact_saved

`FeatureSessionPage.handleArtifactSaved()` calls `reload()` on `useFeatureDetail` —
already wired in `FeatureTabView` — so the saved document appears without a page reload.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| `hermes-agent` GitHub repo | Existing fork | Exists at `/Users/pye/code/voyager/hermes-agent` | **Yes — must be added to `workspace.yaml`** before T1 |
| `anthropic` Python SDK | PyPI optional dep | Already in hermes-agent `pyproject.toml` extras | T1 — ensure `anthropic` extra is installed |
| `fastapi`, `uvicorn`, `asyncpg` | PyPI | `fastapi`+`uvicorn` already direct deps; `asyncpg` must be added | T1 — add `asyncpg` to `pyproject.toml` |
| `ANTHROPIC_API_KEY` | Env var | Not yet in hermes-agent deployment env | **Yes — must be provisioned before T1 testable** |
| `GITHUB_TOKEN` (contents:write) | Env var | Exists in orchestrator | Verify scope covers GitHub Contents API PUT |
| `WORKFLOW_BACKEND_URL` | Env var | New in hermes-agent | T1 — needed by `workflow_plugin` tools |
| `HERMES_AGENT_URL` | Env var | New in workflow-backend | T1b — internal URL of the hermes-agent gateway |
| `gin-contrib/sse` | Go dep | Indirect in go.mod | T1b — promote to direct `require` |
| `@microsoft/fetch-event-source` | npm | Not in digital-factory-ui | T2 — `npm install` |
| Postgres schema | DB migration | New tables in hermes-agent DB | T1 — run at hermes-agent startup |
| `NEXT_PUBLIC_WORKFLOW_API_URL` | Env var | Already in digital-factory-ui | No — reused as-is |

**Unresolved at design time:**
- `hermes-agent` not yet in `workspace.yaml` — **D1, human action required before T1**.
- `GITHUB_TOKEN` `contents:write` scope must be confirmed for GitHub Contents API PUT
  (different from git push).

---

## 6. Parallelization / Blocking Analysis

```
D1: Add hermes-agent repo to workspace.yaml (repos[]) — human action
  └── Required before T1 can be claimed.

T1: hermes-agent — workflow_gateway/ + workflow_plugin/ (read tools)
  └── BLOCKED on D1 (repo must be registered)
      Once D1 done: add workflow_gateway/ (swell-hermes pattern),
      workflow_plugin/ with read tools, hermes_home/config.yaml,
      asyncpg dep, Postgres migration.

T1b: workflow-backend — ChatProxyHandler + 2 proxy routes
  └── BLOCKED on D1 (HERMES_AGENT_URL known after hermes-agent is registered)
      new internal/handler/chat_proxy.go; promote gin-contrib/sse

T2: digital-factory-ui — right-panel layout + chat UI + fetch-event-source client
  └── Can begin now — no blockers
      (mock SSE locally; wire to workflow-backend /chat once T1b merges)

  T1, T1b, and T2 all unblock from D1; T2 can start without D1.

  T3: digital-factory-ui — SlashCommandPicker
    └── BLOCKED on T2 (PromptInput must be in place)

  T4: hermes-agent — write tools + artifact_saved event
    └── BLOCKED on T1 (extends workflow_plugin tool registry)

  T3 and T4 run in parallel (Wave 2)

  T5: digital-factory-ui — artifact_saved handler + document panel refresh
    └── BLOCKED on T2 (streamChatTurn client must be wired)
    └── BLOCKED on T4 (artifact_saved event defined by hermes-agent)

  T5 is Wave 3
```

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `hermes-agent` *(existing fork)* | Add `workflow_gateway/` module + `workflow_plugin/` + `asyncpg` dep + Postgres migrations | Turns the fork into a deployable multi-tenant gateway compatible with our platform |
| `workflow-backend` | New `internal/handler/chat_proxy.go`; 2 new routes; `HERMES_AGENT_URL` config; promote `gin-contrib/sse` | SSE proxy — forwards chat traffic; keeps `HERMES_AGENT_URL` server-side |
| `digital-factory-ui` | New `src/features/agent-chat/`; new `src/services/workflow-backend/chat.ts`; modify `FeatureSessionPage`; add `@microsoft/fetch-event-source` | Right-panel layout, chat UI, SSE client |
| `management-repo` | Add `hermes-agent` entry to `workspace.yaml → repos[]` | Register the forked repo in workspace |

---

## 8. Validation and Release Impact

### Testing
- **hermes-agent (T1/T4):** Unit tests for each `workflow_plugin` tool (mock
  workflow-backend HTTP + GitHub API). Smoke test (`scripts/phase0_smoke.py` pattern
  from swell-hermes) verifying plugin discovery and all 4 tools register at startup.
- **workflow-backend (T1b):** Integration test for `/chat` proxy — stand up a mock
  hermes-agent returning a fixed SSE stream; assert bytes forwarded unchanged; assert
  `artifact_saved` passes through.
- **digital-factory-ui (T2/T3/T5):** Component tests for `SlashCommandPicker`; integration
  test for `streamChatTurn` against a mock SSE server.

### Migration / Config
- New env vars: `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `WORKFLOW_BACKEND_URL` in
  hermes-agent; `HERMES_AGENT_URL` in workflow-backend. Add to respective `.env.example`.
- New Postgres tables in hermes-agent DB (`voyager_sessions_v4`, `voyager_messages_v4` —
  same schema as swell-hermes). No changes to workflow-backend DB.

### Rollout
- hermes-agent gateway is a new service deployed independently. If unreachable,
  `AgentChatPanel` shows an error state; rest of feature view is unaffected.
- All workflow-backend and digital-factory-ui changes are additive.
- Chat panel appears only in `FeatureSessionPage`.

### M2 growth path
The `workflow_gateway/` and `workflow_plugin/` additions are the M2 artifact:
- Persistent memory: plug into `hermes-agent`'s built-in `memory` plugin (already
  in `plugins/memory/`) — additive, no API change.
- `background_review` (learning loop): hook into `on_session_end` in `workflow_plugin/`.
- Resident-VM model: one hermes-agent process per workspace, sessions scoped by
  `workspace_id` in Postgres — already structured this way.
- The SSE event shape and workflow-backend proxy do not change across M2 evolution.

## Reference
- hermes-agent fork: `/Users/pye/code/voyager/hermes-agent`
- swell-hermes gateway pattern: `/Users/pye/code/voyager/swell-hermes`
- voyager-interface chat components: `/Users/pye/code/voyager/voyager-interface/src/components/intelligence/agent/agent-elements/`
- Roadmap M2/M3: `docs/roadmap-milestone.md`
