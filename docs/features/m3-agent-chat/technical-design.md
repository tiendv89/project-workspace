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
- `WorkspaceSessionShell` children area: `flex min-h-0 flex-1 flex-col overflow-hidden`
  — a full-height column with no horizontal split.
- API calls: thin `fetch`-based `request<T>()` in `src/services/workflow-backend/client.ts`.
- **No SSE/streaming client code exists.** voyager uses `@microsoft/fetch-event-source`;
  that library is not in the current dep tree.
- **No chat UI components.** voyager (`voyager-interface`) has production-ready primitives
  (`Conversation`, `MessageThread`, `Message`, `MessageContent`, `PromptInput`, `Loader`)
  on the same HeroUI + TailwindCSS stack — directly portable.

### workflow-backend
- Go 1.25, Gin. All routes are synchronous JSON. No Claude/Anthropic code.
- The adapter layer (`internal/adapter/rpc.go`) calls `workspace-github-adapter` for
  import/sync. No write operations exposed via that RPC layer.
- `gin-contrib/sse` is an indirect dep but is never used.
- **No changes needed to workflow-backend for this feature.**

### voyager_agent (reference implementation — M2 Hermes pattern)
- Python FastAPI service, port 8080.
- **Transport:** HTTP POST → Server-Sent Events (SSE), `text/event-stream`.
- **Session model:** server-assigned UUID (`sess_{hex}`), PostgreSQL-backed
  (`conversations` + `messages` tables), per-user concurrency limit (max 5 active streams).
- **API surface (v5):**
  - `POST /api/v5/create_session` — create and register a session.
  - `POST /api/v5/stream_chat` — stream agent response for one turn.
  - `GET  /api/v5/sessions_by_user` — list user sessions.
  - `GET  /api/v5/full_session` — fetch full conversation history.
- **SSE event envelope** (`format_sse()` → `data: {json}\n\n`, done: `data: [DONE]`):
  - `message_output_partial` — streaming text delta.
  - `tool_call_item` — tool execution started.
  - `function_call_output` — tool result.
  - `usage` — token counts.
  - `error` — stream-level error.
  - `ignored` — rejected (session busy).
- **Tools:** local Python functions + optional MCP servers via `MCPServerStreamableHttp`.
- **Model:** OpenAI GPT-5.1 in voyager; Hermes for this platform uses
  Claude (`claude-sonnet-4-6`) via the Anthropic Python SDK, normalised to the same
  SSE event format.
- **Auth:** Bearer token in `Authorization` header + session-ownership check.
- **Frontend client:** `@microsoft/fetch-event-source` with Zustand store.

### workspace.yaml — current state
No `hermes-agent` repo entry exists. One must be added before T1 can be executed.

---

## 2. Problem Framing

### What needs to change
1. A **Hermes agent service** (Python FastAPI, `voyager_agent` pattern) must be built and
   deployed. It exposes the same `/api/v5/create_session` + `/api/v5/stream_chat` contract
   but with workflow-specific tools instead of trading tools.
2. The layout of the feature view must be split horizontally: existing content on the left,
   a new always-visible chat panel on the right.
3. The frontend must manage Hermes sessions (create + stream), render messages, and handle
   the slash-command picker.
4. When the agent writes an artifact (`write_product_spec`, `write_technical_design`), the
   frontend must refresh the corresponding document panel.

### What must remain stable
- The existing `FeatureTabView` panels and all four document/task/log views.
- workflow-backend routes — this feature adds no changes there.
- The workflow lifecycle gates — agent drafts; human approves via `/approve-feature`.
- The voyager SSE event envelope — the hermes-agent emits the same event types so the
  frontend client is reusable across both products.

### Fixed assumptions
- Hermes uses `claude-sonnet-4-6` (matches `workspace.yaml → model_policy.implementation.default`).
- Session persistence uses the same PostgreSQL instance as workflow-backend (separate schema
  or separate DB — operator's choice), not a new datastore.
- `ANTHROPIC_API_KEY` and `GITHUB_TOKEN` are available in the hermes-agent env.
- `workspace_id` and `feature_id` are passed with every `stream_chat` request so the agent
  can scope context and tool execution to the correct feature.

---

## 3. Options Considered

### Option A — Claude API directly in workflow-backend (Go)
Add `anthropic-sdk-go` to workflow-backend, new SSE endpoint there.

- **Pros:** No new service; single deploy unit.
- **Cons:** Incompatible with M2 Hermes deployment — when Hermes ships, the frontend
  would need to be re-wired from workflow-backend to Hermes. The session model, tool
  registry, and memory/learning loop all belong in the agent layer, not the data API.
  Forces Go to carry Python-idiomatic agent code.
- **Rejected.** Produces throwaway work that M2 replaces.

### Option B — Hermes agent service (Python FastAPI, voyager pattern) — chosen
Build `hermes-agent` as a standalone Python FastAPI service following `voyager_agent` v5.
The frontend connects directly to Hermes; workflow-backend stays a pure data API.

- **Pros:** M2-compatible from day one — the same service grows into full Hermes as M2
  matures. Same SSE contract as voyager means frontend code is already proven. Tool
  registry is in Python where agent-native libraries (`anthropic`, MCP) are best supported.
- **Cons:** New service to deploy; requires adding `hermes-agent` to `workspace.yaml`.
- **Chosen.**

### Option C — Next.js API route proxy + Vercel AI SDK
Next.js API route calls Claude, streams via Vercel AI SDK protocol.

- **Cons:** ANTHROPIC_API_KEY in Next.js env; write tools require a second HTTP hop back
  to some backend; incompatible with Hermes session model. Rejected.

---

## 4. Chosen Design

### Hermes agent service

A new Python FastAPI service (`hermes-agent` repo) modelled directly on `voyager_agent/`.
Structure mirrors voyager but with workflow-domain tools and Claude as the LLM.

```
hermes-agent/
├── agent.py                      ← FastAPI app entry point (lifespan, routers)
├── src/
│   ├── app/
│   │   └── agent_v5/
│   │       ├── api/
│   │       │   └── router.py     ← /create_session, /stream_chat endpoints
│   │       ├── orchestration/
│   │       │   ├── session_manager.py   ← session CRUD + streaming coordination
│   │       │   ├── executor.py          ← format_sse(), stream loop
│   │       │   └── agent.py             ← build_agent() factory, Claude model
│   │       ├── tools/
│   │       │   └── registry.py          ← workflow tool definitions
│   │       └── models/
│   │           ├── api_models.py
│   │           └── session.py
│   └── configs/
│       └── settings.yaml
├── requirements.txt
└── Dockerfile
```

**API contract** (identical to voyager_agent v5):

```
POST /api/v5/create_session
  Body:  { "user_id": "<string>" }
  Returns: { "session_id": "sess_<hex>" }

POST /api/v5/stream_chat
  Body:  { "session_id": "...", "message": "...", "workspace_id": "...", "feature_id": "..." }
  Auth:  Authorization: Bearer <token>
  Returns: text/event-stream, JSON events, done: "data: [DONE]"
```

**SSE event types emitted** (same envelope as voyager):

| Event type | Payload | When |
|---|---|---|
| `message_output_partial` | `{ "content": "<text>" }` | Each streaming text token |
| `tool_call_item` | `{ "call_id": "...", "name": "<tool>", "status": "running" }` | Tool invocation starts |
| `function_call_output` | `{ "call_id": "...", "name": "<tool>", "output": {...} }` | Tool result |
| `artifact_saved` | `{ "artifact": "product_spec" \| "technical_design" }` | Write tool succeeded |
| `usage` | `{ "input": N, "output": N, "cached": N }` | End of turn |
| `error` | `{ "message": "..." }` | Stream-level error |
| `ignored` | `{ "reason": "session_busy" }` | Concurrent stream blocked |

**Model integration:**
The `executor.py` uses `anthropic.AsyncAnthropic().messages.stream()` with
`model="claude-sonnet-4-6"`, a system prompt, the conversation history, and tool
definitions. Text deltas are normalised to `message_output_partial` events; tool use
blocks to `tool_call_item` / `function_call_output` — same envelope voyager emits from
the OpenAI Agents SDK. The frontend does not need to know which LLM is underneath.

**Session persistence:**
`SessionManager` stores sessions in PostgreSQL with the same `conversations` +
`messages` table shape as voyager. `workspace_id` + `feature_id` are stored in the
session record so tools can scope themselves without the client repeating them.

**Workflow tool registry** (4 tools, v1):

| Tool | Action | Implementation |
|---|---|---|
| `get_workspace_context` | Return workspace metadata | HTTP GET to workflow-backend `/api/workspaces/:id` |
| `get_feature_state` | Return feature status + existing artifact content | HTTP GET to workflow-backend `/api/workspaces/:id/features/:id` + raw Markdown from GitHub Contents API |
| `write_product_spec` | Write draft to management repo | GitHub Contents API `PUT /repos/{owner}/{repo}/contents/docs/features/{id}/product-spec.md` using `GITHUB_TOKEN` |
| `write_technical_design` | Write draft to management repo | Same, `technical-design.md` |

After a successful write, the tool execution loop emits `artifact_saved` before the
turn-end `usage` event. The frontend uses this to trigger a document panel refresh.

**System prompt** (injected per-turn, not stored):
- Workspace name, available repos from `get_workspace_context`.
- Current feature lifecycle stage and existing artifact excerpts.
- Instruction: "You draft artifacts through tools; you never advance lifecycle state directly;
  the human approves via the existing approval flow."

---

### Layout change (digital-factory-ui)

Modify `FeatureSessionPage` to wrap its children in a horizontal flex container.
`WorkspaceSessionShell` already wraps with `flex min-h-0 flex-1 flex-col overflow-hidden`;
the horizontal split lives one level below that, inside `FeatureSessionPage`:

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

### Chat panel UI components (digital-factory-ui)

New module: `src/features/agent-chat/`

Port directly from `voyager-interface/src/components/intelligence/agent/agent-elements/`:
- `conversation.tsx` → `Conversation`, `ConversationContent`, `ConversationScrollButton`
- `message.tsx` → `Message`, `MessageContent`
- `message-thread.tsx` → `MessageThread` (simplified — no chart/UI-block parts)
- `loader.tsx` → `Loader`
- `prompt-input.tsx` → `PromptInput`, `PromptInputTextarea`, `PromptInputToolbar`,
  `PromptInputSubmit`

New component (not in voyager):
- `slash-command-picker.tsx` — popover above the input when textarea value starts with `/`;
  filters a static `COMMANDS` registry in real time; arrow-key + Enter or click inserts
  the command name into the input; Escape or deleting the `/` dismisses.

```ts
const COMMANDS = [
  { name: "/write-product-spec",     hint: "Draft or update the product spec" },
  { name: "/write-technical-design", hint: "Draft or update the technical design" },
  { name: "/get-feature-state",      hint: "Show current feature lifecycle state" },
  { name: "/get-workspace-context",  hint: "Show repos, roles, model policy" },
];
```

`AgentChatPanel` orchestrates session lifecycle (create on mount, persist `session_id`
in component state) and feeds messages + status into `MessageThread`.

---

### Hermes API client (digital-factory-ui)

New file: `src/services/hermes-agent/client.ts`

Two functions:
1. `createSession(userId: string): Promise<{ session_id: string }>` — `POST /api/v5/create_session`.
2. `streamChatTurn(params, onEvent, onDone, onError)` — wraps `fetchEventSource` from
   `@microsoft/fetch-event-source`; dispatches typed events to the caller.

```ts
// Event union the caller receives
type HermesEvent =
  | { type: "delta"; text: string }
  | { type: "tool_start"; name: string }
  | { type: "tool_result"; name: string; output: unknown }
  | { type: "artifact_saved"; artifact: "product_spec" | "technical_design" }
  | { type: "error"; message: string }
  | { type: "done" };
```

`NEXT_PUBLIC_HERMES_AGENT_URL` env var controls the base URL (mirrors voyager's
`NEXT_PUBLIC_AGENT_SERVICE_API`).

---

### Document refresh on artifact_saved (digital-factory-ui)

`FeatureSessionPage` passes an `onArtifactSaved` callback to `AgentChatPanel`. When the
callback fires (with `artifact: "product_spec" | "technical_design"`), the page calls
`reload()` on the `useFeatureDetail` hook — already available from `FeatureTabView`'s
existing data-fetch pattern — so the saved document appears in the tab without a
page reload.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| `hermes-agent` GitHub repo | New repo | Does not exist | Yes — must be created and added to `workspace.yaml` before T1 |
| `anthropic` Python SDK | PyPI dep | Not in hermes-agent (new repo) | T1 — add to `requirements.txt` |
| `fastapi`, `uvicorn`, `asyncpg` | PyPI deps | Standard; same as voyager | T1 — add to `requirements.txt` |
| `ANTHROPIC_API_KEY` | Env var | Not yet in hermes-agent env | Yes — must be provisioned before T1 is testable end-to-end |
| `GITHUB_TOKEN` with `contents:write` | Env var | Exists in orchestrator env | Needs confirming scope covers management repo write via Contents API |
| Workflow-backend URL | Service dep | Running locally + deployed | T1 tools — `get_workspace_context` and `get_feature_state` call it via HTTP |
| `@microsoft/fetch-event-source` | npm dep | Not in digital-factory-ui | T2 — `npm install` |
| PostgreSQL | DB | Shared instance | T1 — new schema/tables (`hermes_sessions`, `hermes_messages`); no migration to existing tables |
| `NEXT_PUBLIC_HERMES_AGENT_URL` | Env var | Does not exist | T2 — add to `.env.local` + deployment config |

**Unresolved at design time:**
- `hermes-agent` repo does not exist in `workspace.yaml`. This must be resolved before
  any task in this feature can be claimed. **D1 below.**
- `GITHUB_TOKEN` `contents:write` scope: the orchestrator uses the token for git push,
  not for the GitHub Contents REST API. These are different auth surfaces. Verify the
  token has `contents:write` via the GitHub API before T4.

---

## 6. Parallelization / Blocking Analysis

```
D1: Create hermes-agent GitHub repo + add to workspace.yaml
  └── Must be done by the human before any agent claims T1.
      (Register under repos[] id: hermes-agent, base_branch: main)

T1: hermes-agent — FastAPI skeleton + create_session + stream_chat + read tools
  └── BLOCKED on D1 (repo must exist to push to)
      Once D1 is done: Can begin immediately

T2: digital-factory-ui — Right-panel layout + chat UI + fetch-event-source client
  └── Can begin now — no blockers
      (Mock the SSE stream locally; wire to real Hermes URL once T1 merges)

  T1 and T2 run in parallel after D1

  T3: digital-factory-ui — Slash-command picker
    └── BLOCKED on T2 (PromptInput must be in place to extend with picker popover)

  T4: hermes-agent — Write tools (write_product_spec, write_technical_design) + artifact_saved event
    └── BLOCKED on T1 (extends T1's tool registry and stream loop)

  T3 and T4 run in parallel (Wave 2)

  T5: digital-factory-ui — artifact_saved handler + FeatureTabView document refresh
    └── BLOCKED on T2 (streamChatTurn client must be wired)
    └── BLOCKED on T4 (artifact_saved event defined and emitted by hermes-agent)

  T5 is Wave 3 — both T2 and T4 must be merged first
```

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `hermes-agent` *(new)* | New Python FastAPI service — full agent skeleton, session management, SSE streaming, 4 tools | This is the Hermes agent (M2-compatible) |
| `digital-factory-ui` | New `src/features/agent-chat/`; new `src/services/hermes-agent/client.ts`; modify `FeatureSessionPage` for horizontal split; add `@microsoft/fetch-event-source` | UI components, layout, streaming client |
| `workflow-backend` | **None** | No chat code goes here; existing read endpoints serve as tool targets |
| `management-repo` | Add `hermes-agent` to `workspace.yaml → repos[]` | Register the new repo in the workspace |

---

## 8. Validation and Release Impact

### Testing
- **T1/T4 (hermes-agent):** Unit tests for each tool function (mock workflow-backend HTTP
  responses and GitHub API). Integration test for `POST /stream_chat` end-to-end with a
  real Anthropic API call (lower-priority, can be skipped in CI with `ANTHROPIC_API_KEY`
  absent check).
- **T2/T3/T5 (digital-factory-ui):** Component tests for `SlashCommandPicker` (filter
  logic, keyboard nav). Integration test for `streamChatTurn` against a mock SSE server.
  Visual regression check that the horizontal split renders correctly at 1280 px+ width.

### Migration / Config
- New env vars: `ANTHROPIC_API_KEY` (hermes-agent), `GITHUB_TOKEN` (hermes-agent),
  `NEXT_PUBLIC_HERMES_AGENT_URL` (digital-factory-ui). Add to `.env.template` in both repos.
- New PostgreSQL tables (`hermes_sessions`, `hermes_messages`) in the hermes-agent DB.
  Goose or Alembic migration at service startup.
- No changes to workflow-backend DB schema.

### Rollout
- The chat panel appears only in `FeatureSessionPage` (feature detail view). Board and task
  views are unaffected.
- The hermes-agent service is deployed independently; if it is unreachable, `AgentChatPanel`
  shows an error state — the rest of the UI is unaffected.
- No breaking changes to existing API surface.

### Backward Compatibility
- All existing workflow-backend routes unchanged.
- M2 Hermes evolution (persistent memory, learning loop, `background_review`) is additive
  on top of T1's skeleton — the session model, SSE contract, and frontend client do not
  need to change when those capabilities are added.
