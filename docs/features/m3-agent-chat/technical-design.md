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
- `@microsoft/fetch-event-source` is not in the dep tree. Voyager uses it — directly
  portable.
- **No chat UI components.** Voyager's `voyager-interface` has production-ready primitives
  (`Conversation`, `MessageThread`, `Message`, `PromptInput`, `Loader`) on the same
  HeroUI + TailwindCSS stack.

### workflow-backend
- Go 1.25, Gin, PostgreSQL (pgx v5). All routes return synchronous JSON.
- `gin-contrib/sse v1.1.1` is an indirect dep (via Gin) — never used directly today.
- **workflow-backend's mission includes forwarding the agent stream to the frontend.**
  New proxy endpoints will be added (Section 4). `HERMES_AGENT_URL` lives here —
  never in the browser environment.
- No write operations to the management repo exist today; no Claude/Anthropic code exists.

### swell-hermes (reference implementation — direct template for hermes-agent)
`/Users/pye/code/voyager/swell-hermes` is the exact pattern to follow for the new
`hermes-agent` service. Its architecture:

```
Frontend ──SSE──▶ gateway (FastAPI)          ← auth, billing, sessions, approval, streaming
                       │ imports as library
                       ▼
                  hermes (vendored submodule) ← LLM loop, tool dispatch, plugin discovery
                       │ scans plugins/
                       ▼
                  voyager_plugin              ← domain tools (place_order, positions, …)
```

Key swell-hermes findings:
- **Gateway** (`gateway/app.py`): FastAPI factory that embeds Hermes as an in-process
  library. Modules: `api/` (routes), `auth/` (JWT), `billing/` (credit gate + burn),
  `sessions/` (asyncpg Postgres), `approval/` (human-in-loop registry),
  `streaming/` (SSE translation layer).
- **Hermes core** (`vendor/hermes-agent/` git submodule): `AIAgent` class in
  `run_agent.py`. Invoked as `agent.run_conversation(user_message, conversation_history,
  ...)`. Supports pre/post hooks, plugin tool registration, concurrent tool dispatch,
  context compression, optional memory (disabled for us).
- **Plugin system** (`hermes_cli/plugins.py`): scans 4 locations at startup; each plugin
  has a `plugin.yaml` manifest and a `register(ctx)` entry point. `ctx.register_tool()`
  adds tools; `ctx.register_hook()` adds lifecycle callbacks.
- **SSE shape** (`gateway/streaming/`): translates Hermes internal events to the exact
  same SSE envelope that `voyager_agent` emits (`message_output_partial`,
  `tool_call_item`, `function_call_output`, `usage`, `error`, `ignored`, `[DONE]`).
  The frontend SSE client must not change between voyager and this platform.
- **DB schema** (`migrations/`): `voyager_sessions_v4` + `voyager_messages_v4` tables,
  same as `voyager_agent`. Session storage is owned by the gateway, not by Hermes.
- **Config** (`hermes_home/config.yaml`): minimal YAML deep-merged over Hermes defaults;
  enables the domain plugin.
- **Phase 0 is complete** in swell-hermes: foundation boots, plugin discovery works,
  3 tools register. Our `hermes-agent` starts from this same Phase 0 baseline.

---

## 2. Problem Framing

### What needs to change
1. A **hermes-agent service** (`hermes-agent` repo, modelled on swell-hermes) must be
   created. It replaces `voyager_plugin` with `workflow_plugin` — tools for reading
   workspace/feature context and writing artifacts.
2. **workflow-backend** gains transparent SSE proxy endpoints that forward the frontend's
   chat traffic to hermes-agent. `HERMES_AGENT_URL` is a workflow-backend env var.
3. The **feature view layout** gains a fixed right-side chat panel (horizontal split in
   `FeatureSessionPage`).
4. The **frontend** manages sessions via workflow-backend proxy routes and consumes the
   forwarded SSE stream using `@microsoft/fetch-event-source`.
5. An `artifact_saved` SSE event triggers document panel refresh in the frontend.

### What must remain stable
- All existing `FeatureTabView` panels and workflow-backend routes — purely additive.
- The workflow lifecycle gates — agent drafts; human approves via `/approve-feature`.
- The voyager SSE event envelope — hermes-agent uses the identical shape so the
  `use-chat` pattern from voyager-interface ports unchanged.

### Fixed assumptions
- Hermes uses `claude-sonnet-4-6` (per `workspace.yaml → model_policy.implementation.default`).
- `ANTHROPIC_API_KEY` and `GITHUB_TOKEN` live in hermes-agent's environment.
- The frontend never reaches hermes-agent directly; all traffic routes through
  workflow-backend proxy endpoints using the existing `NEXT_PUBLIC_WORKFLOW_API_URL`.
- `workspace_id` and `feature_id` are forwarded from the frontend → workflow-backend →
  hermes-agent in the `stream_chat` request body so tools can scope correctly.

---

## 3. Options Considered

### Option A — Claude API directly in workflow-backend (Go)
Add `anthropic-sdk-go` to workflow-backend.

- **Rejected.** Incompatible with M2 — when Hermes is promoted to full resident
  teammate, the frontend would need re-wiring. Agent session model, plugin system,
  and memory/learning loop belong in the Python agent layer, not a Go data API.

### Option B — hermes-agent (swell-hermes pattern) + workflow-backend SSE proxy — chosen
hermes-agent is a standalone Python FastAPI service (gateway → Hermes library →
workflow_plugin). workflow-backend adds a thin proxy. Frontend uses existing
`NEXT_PUBLIC_WORKFLOW_API_URL`.

- **Chosen.** M2-compatible from day one. swell-hermes is a nearly complete template —
  we replace `voyager_plugin` with `workflow_plugin` and swap trading tools for
  workspace tools. Frontend client pattern (fetch-event-source) is already proven in
  voyager-interface.

### Option C — Next.js API route + Vercel AI SDK
- **Rejected.** API key in Next.js env; incompatible with Hermes session model; no
  plugin system.

---

## 4. Chosen Design

### 4.1 hermes-agent service (new repo)

Clone the swell-hermes structure, replacing `voyager_plugin` with `workflow_plugin`:

```
hermes-agent/
├── gateway/                       ← copy from swell-hermes/gateway/ (all modules)
│   ├── app.py                     ← FastAPI factory (API prefix: /api/v5)
│   ├── api/router.py              ← /create_session, /stream_chat
│   ├── auth/                      ← JWT verify (simplified: no Privy/credits for v1)
│   ├── sessions/                  ← asyncpg Postgres session + message store
│   ├── streaming/                 ← SSE event translation (Hermes → SSE envelope)
│   └── approval/                  ← human-in-loop registry (stub for v1)
├── workflow_plugin/               ← our domain tools (replaces voyager_plugin/)
│   ├── __init__.py                ← register(ctx) entry point
│   ├── tools.py                   ← tool schemas + handlers
│   ├── client.py                  ← WorkflowClient (HTTP wrapper for workflow-backend)
│   └── plugin.yaml                ← manifest: name: workflow, provides_tools: [...]
├── vendor/hermes-agent/           ← git submodule (same as swell-hermes)
├── hermes_home/config.yaml        ← enables workflow plugin; model: claude-sonnet-4-6
├── migrations/                    ← copy from swell-hermes/migrations/ (schema unchanged)
├── pyproject.toml                 ← fastapi, uvicorn, httpx, asyncpg
└── Dockerfile
```

**API contract** (identical to swell-hermes / voyager_agent v5):

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

**SSE event types** (identical envelope to swell-hermes `gateway/streaming/`):

| Event | Payload | When |
|---|---|---|
| `message_output_partial` | `{ "content": "<text>" }` | Each streaming text token |
| `tool_call_item` | `{ "call_id": "...", "name": "<tool>", "status": "running" }` | Tool starts |
| `function_call_output` | `{ "call_id": "...", "name": "<tool>", "output": {...} }` | Tool result |
| `artifact_saved` | `{ "artifact": "product_spec" \| "technical_design" }` | Write tool done |
| `usage` | `{ "input": N, "output": N, "cached": N }` | End of turn |
| `error` | `{ "message": "..." }` | Stream error |
| `ignored` | `{ "reason": "session_busy" }` | Concurrent stream blocked |

`artifact_saved` is a new event type added to the streaming layer on top of swell-hermes.

**workflow_plugin — tool registry:**

```python
# workflow_plugin/plugin.yaml
name: workflow
version: 0.1.0
provides_tools:
  - workflow_get_workspace_context
  - workflow_get_feature_state
  - workflow_write_product_spec
  - workflow_write_technical_design

# workflow_plugin/__init__.py
def register(ctx):
    for name, schema, handler in _TOOLS:
        ctx.register_tool(name=name, toolset="workflow",
                          schema=schema, handler=handler,
                          check_fn=check_workflow_available)
    ctx.register_hook("pre_llm_call", _inject_feature_context)
```

| Tool | Handler | Implementation |
|---|---|---|
| `workflow_get_workspace_context` | `handle_get_workspace_context` | `GET {WORKFLOW_BACKEND_URL}/api/workspaces/{workspace_id}` |
| `workflow_get_feature_state` | `handle_get_feature_state` | GET feature detail + GitHub Contents API for raw artifact Markdown |
| `workflow_write_product_spec` | `handle_write_product_spec` | GitHub Contents API `PUT /repos/{owner}/{repo}/contents/docs/features/{id}/product-spec.md` |
| `workflow_write_technical_design` | `handle_write_technical_design` | Same path, `technical-design.md` |

`_inject_feature_context` pre_llm_call hook injects workspace name, available repos,
and feature lifecycle state into the system prompt at the start of each turn (same
pattern as voyager's position/skill-catalog injection).

**hermes_home/config.yaml:**
```yaml
plugins:
  enabled:
    - workflow
agent:
  model: claude-sonnet-4-6
  provider: anthropic
```

---

### 4.2 workflow-backend SSE proxy

workflow-backend adds a `ChatProxyHandler` that forwards traffic transparently between
the frontend and hermes-agent. No event parsing, no buffering, no transformation —
byte-pipe only. `HERMES_AGENT_URL` is an env var (e.g. `http://hermes-agent:8000`).

**Two new routes** added to `WorkspaceHandler.RegisterRoutes()`:

```
POST /api/workspaces/:workspaceId/features/:featureId/chat/session
  → proxies to: POST {HERMES_AGENT_URL}/api/v5/create_session
  → forwards Authorization header from frontend request

POST /api/workspaces/:workspaceId/features/:featureId/chat
  → proxies to: POST {HERMES_AGENT_URL}/api/v5/stream_chat
  → injects workspace_id + feature_id into forwarded body
  → pipes response bytes back with Content-Type: text/event-stream
  → uses gin's c.Stream() + http.Flusher pattern
  → promotes gin-contrib/sse from indirect to direct require
```

The proxy implementation in Go (`internal/handler/chat_proxy.go`):
```go
// ChatProxy handler: forward body to hermes, pipe SSE bytes back.
// No event parsing — transparent byte-pipe.
func (h *ChatProxyHandler) StreamChat(c *gin.Context) {
    // 1. Read body, inject workspace_id + feature_id
    // 2. POST to HERMES_AGENT_URL/api/v5/stream_chat, forward Authorization
    // 3. c.Stream() → io.Copy(c.Writer, hermesResp.Body) with c.Writer.Flush()
}
```

A new `ChatProxyHandler` struct (separate from `WorkspaceHandler`) keeps the proxy
concern isolated. It takes `hermesBaseURL string` injected at startup.

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
- `MessageThread` — renders messages, `Loader` while streaming
- `PromptInput` / `PromptInputTextarea` / `PromptInputToolbar` / `PromptInputSubmit`

New component (not in voyager): `SlashCommandPicker` — popover above the input when
the textarea value starts with `/`; filters a static registry in real time; arrow-key +
Enter or click inserts the command; Escape dismisses.

```ts
const COMMANDS = [
  { name: "/write-product-spec",     hint: "Draft or update the product spec" },
  { name: "/write-technical-design", hint: "Draft or update the technical design" },
  { name: "/get-feature-state",      hint: "Show current feature lifecycle state" },
  { name: "/get-workspace-context",  hint: "Show repos, roles, model policy" },
];
```

`AgentChatPanel` manages session lifecycle: calls `/chat/session` on mount, persists
`session_id` in component state, feeds messages + stream status into `MessageThread`.

---

### 4.5 Hermes API client (digital-factory-ui)

New file: `src/services/workflow-backend/chat.ts` — uses the existing
`NEXT_PUBLIC_WORKFLOW_API_URL` base. No new env var needed in the frontend.

```ts
// Create a hermes session scoped to a feature
createChatSession(workspaceId, featureId, userId): Promise<{ session_id: string }>
// → POST /api/workspaces/:wid/features/:fid/chat/session

// Stream one chat turn
streamChatTurn(params, onEvent, onDone, onError): AbortController
// → fetchEventSource POST /api/workspaces/:wid/features/:fid/chat
```

Event union:
```ts
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
already wired in `FeatureTabView`. The saved document appears in the tab with no page
reload.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| `hermes-agent` GitHub repo | New repo | Does not exist | **Yes** — must be created and added to `workspace.yaml` before T1 |
| `vendor/hermes-agent` submodule | git submodule | Exists in swell-hermes | T1 — point submodule at same commit as swell-hermes |
| `anthropic` Python SDK | PyPI | In swell-hermes `vendor/` venv | T1 — `hermes_home/config.yaml` sets provider: anthropic |
| `ANTHROPIC_API_KEY` | Env var | Not yet in hermes-agent env | **Yes** — must be provisioned before T1 testable end-to-end |
| `GITHUB_TOKEN` (contents:write) | Env var | Exists in orchestrator | Verify `contents:write` scope covers GitHub Contents API PUT — different from git push |
| `WORKFLOW_BACKEND_URL` | Env var | New in hermes-agent | T1 — needed by `workflow_plugin` tools |
| `HERMES_AGENT_URL` | Env var | New in workflow-backend | T1b — internal URL for the proxy handler |
| `gin-contrib/sse` | Go dep | Indirect in go.mod | T1b — promote to direct `require` for proxy flusher |
| `@microsoft/fetch-event-source` | npm dep | Not in digital-factory-ui | T2 — `npm install` |
| PostgreSQL schema | DB migration | Copied from swell-hermes | T1 — run at hermes-agent startup |
| `NEXT_PUBLIC_WORKFLOW_API_URL` | Env var | Already in digital-factory-ui | No — reused as-is for /chat routes |

**Unresolved at design time:**
- `hermes-agent` repo does not exist (**D1 — must be resolved by the human first**).
- `GITHUB_TOKEN` scope: verify `contents:write` via the GitHub API before T4.

---

## 6. Parallelization / Blocking Analysis

```
D1: Create hermes-agent GitHub repo + add to workspace.yaml (repos[])
  └── Human action. Must complete before any agent claims T1 or T1b.

T1: hermes-agent — scaffold from swell-hermes + workflow_plugin read tools
  └── BLOCKED on D1 (repo must exist)
      • Copy gateway/ from swell-hermes; replace voyager_plugin/ with workflow_plugin/
      • Implement get_workspace_context + get_feature_state tools
      • Wire hermes_home/config.yaml: model claude-sonnet-4-6, plugin: workflow
      • Copy migrations/ from swell-hermes
      • Dockerfile + pyproject.toml

T1b: workflow-backend — ChatProxyHandler + two proxy routes
  └── BLOCKED on D1 (HERMES_AGENT_URL must be known)
      • New internal/handler/chat_proxy.go
      • Register routes in cmd/api/api.go
      • Promote gin-contrib/sse to direct dep

T2: digital-factory-ui — right-panel layout + chat UI components + SSE client
  └── Can begin now — no blockers
      (mock fetchEventSource locally; wire to workflow-backend /chat once T1b merges)

  T1 and T1b are co-dependent (develop in same feature branch, T1b configures
  HERMES_AGENT_URL pointing at T1 service). T2 runs in parallel with both.

  T3: digital-factory-ui — SlashCommandPicker
    └── BLOCKED on T2 (PromptInput must be in place to extend)

  T4: hermes-agent — write tools (write_product_spec, write_technical_design) + artifact_saved event
    └── BLOCKED on T1 (extends T1's workflow_plugin tool registry)

  T3 and T4 run in parallel (Wave 2)

  T5: digital-factory-ui — artifact_saved handler + document panel auto-refresh
    └── BLOCKED on T2 (streamChatTurn client must be wired)
    └── BLOCKED on T4 (artifact_saved event emitted by hermes-agent)

  T5 is Wave 3 — both T2 and T4 must merge first
```

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `hermes-agent` *(new)* | Full new service: gateway (FastAPI), workflow_plugin, Hermes submodule, migrations | M2-compatible agent; reads workspace context; writes artifacts via GitHub API |
| `workflow-backend` | New `internal/handler/chat_proxy.go`; 2 new routes; `HERMES_AGENT_URL` config; promote `gin-contrib/sse` | SSE proxy — forwards frontend chat traffic to hermes-agent; keeps `HERMES_AGENT_URL` server-side |
| `digital-factory-ui` | New `src/features/agent-chat/`; new `src/services/workflow-backend/chat.ts`; modify `FeatureSessionPage`; add `@microsoft/fetch-event-source` | Right-panel layout, chat UI, SSE client |
| `management-repo` | Add `hermes-agent` entry to `workspace.yaml → repos[]` | Register new repo in workspace |

---

## 8. Validation and Release Impact

### Testing
- **hermes-agent (T1/T4):** Unit tests per tool (mock workflow-backend + GitHub API HTTP).
  Smoke test (`scripts/phase0_smoke.py` pattern from swell-hermes) verifying plugin
  discovery and all 4 tools register at startup.
- **workflow-backend (T1b):** Integration test for `/chat` proxy endpoint — stand up
  a mock hermes-agent returning a fixed SSE stream; assert bytes are forwarded
  unchanged; assert `artifact_saved` event passes through.
- **digital-factory-ui (T2/T3/T5):** Component tests for `SlashCommandPicker` (filter
  logic, keyboard nav). Integration test for `streamChatTurn` against a mock SSE server.

### Migration / Config
- New env vars: `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `WORKFLOW_BACKEND_URL` in
  hermes-agent; `HERMES_AGENT_URL` in workflow-backend. Add to `.env.example` / `.env.template`.
- New Postgres tables in hermes-agent DB (`voyager_sessions_v4`, `voyager_messages_v4`
  — copied verbatim from swell-hermes migrations). No changes to workflow-backend DB.
- `@microsoft/fetch-event-source` added to digital-factory-ui package.json.

### Rollout
- hermes-agent is a new service deployed independently. If unreachable, `AgentChatPanel`
  shows an error state; the rest of the feature view is unaffected.
- workflow-backend proxy routes are additive — zero impact on existing endpoints.
- Chat panel appears only in `FeatureSessionPage`. Board and task views unchanged.

### M2 growth path
The hermes-agent skeleton created here (gateway + Hermes submodule + workflow_plugin)
is the same artifact M2 grows into:
- Persistent memory and `background_review` are additive on top of the Hermes
  submodule — no API contract change.
- The `pre_llm_call` hook in `workflow_plugin` is where workspace-scoped learning
  (injecting accumulated context) will plug in.
- The resident-VM deployment model (one agent per workspace) maps directly to the
  session model: `workspace_id`-scoped sessions, one hermes-agent instance per workspace.
- The frontend client and SSE event shape do not change across M2 evolution.

## Reference
- swell-hermes pattern: `/Users/pye/code/voyager/swell-hermes/`
- voyager-interface chat components: `/Users/pye/code/voyager/voyager-interface/src/components/intelligence/agent/agent-elements/`
- Roadmap M2/M3: `docs/roadmap-milestone.md`
