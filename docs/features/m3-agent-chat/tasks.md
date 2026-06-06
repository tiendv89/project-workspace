# m3-agent-chat — Task Breakdown

**Feature status:** `in_tdd` | **Stage:** `tasks` (awaiting approval)
Machine-readable state lives in `tasks/T<n>.yaml`. This file is narrative only.

## Index

| ID  | Wave | Title                                              | Depends on |
|-----|------|----------------------------------------------------|------------|
| T1  | 1    | hermes-agent: workflow_gateway + workflow_plugin read tools | —      |
| T2  | 1    | workflow-backend: ChatProxyHandler SSE proxy       | —          |
| T3  | 1    | digital-factory-ui: right-panel layout + chat UI + SSE client | —  |
| T4  | 2    | digital-factory-ui: SlashCommandPicker             | T3         |
| T5  | 2    | hermes-agent: write tools + artifact_saved event   | T1         |
| T6  | 3    | digital-factory-ui: artifact_saved handler + document refresh | T3, T5 |

---

## T1 — hermes-agent: workflow_gateway + workflow_plugin read tools

### Description
Add two new top-level directories to the hermes-agent fork:

`workflow_gateway/` — a FastAPI gateway that embeds `AIAgent` as an in-process library
(swell-hermes pattern). Handles session management (asyncpg Postgres), SSE event
translation from Hermes callbacks to the voyager SSE envelope, and auth stub for v1.
Exposes `POST /api/v5/create_session` and `POST /api/v5/stream_chat`.

`workflow_plugin/` — a Hermes plugin (`register(ctx)` entry point, `plugin.yaml`
manifest) that registers 2 read tools for v1:
- `workflow_get_workspace_context` — HTTP GET to workflow-backend `/api/workspaces/{id}`
- `workflow_get_feature_state` — GET feature detail + raw artifact Markdown via
  workflow-backend and GitHub Contents API

Also adds a `pre_llm_call` hook to inject workspace/feature context into every turn's
system prompt, and configures `hermes_home/config.yaml` to use `claude-sonnet-4-6` via
the `anthropic` provider.

Postgres migration (schema copied from swell-hermes): `voyager_sessions_v4` +
`voyager_messages_v4` tables. `asyncpg` added to `pyproject.toml`.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Create `workflow_gateway/app.py` — FastAPI factory, `/api/v5` prefix, lifespan
- [ ] Create `workflow_gateway/api/router.py` — `create_session`, `stream_chat` routes
- [ ] Create `workflow_gateway/sessions/__init__.py` — asyncpg Postgres CRUD
- [ ] Create `workflow_gateway/streaming/__init__.py` — Hermes callbacks → SSE envelope
- [ ] Create `workflow_gateway/auth/__init__.py` — JWT stub (v1: pass-through)
- [ ] Create `workflow_plugin/__init__.py` — `register(ctx)` with read tools + `pre_llm_call`
- [ ] Create `workflow_plugin/tools.py` — `handle_get_workspace_context`, `handle_get_feature_state`
- [ ] Create `workflow_plugin/client.py` — `WorkflowClient` HTTP wrapper
- [ ] Create `workflow_plugin/plugin.yaml` — manifest
- [ ] Create `hermes_home/config.yaml` — enable `workflow` plugin, model: claude-sonnet-4-6, provider: anthropic
- [ ] Add `asyncpg` to `pyproject.toml`; ensure `anthropic` extra is installable
- [ ] Add Postgres migration files (copy from swell-hermes schema)
- [ ] Add `.env.example` with `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `WORKFLOW_BACKEND_URL`, `DATABASE_URL`
- [ ] Add `Dockerfile` / startup command: `uvicorn workflow_gateway.app:app --host 0.0.0.0 --port 8000`
- [ ] Smoke test: plugin discovery registers all tools at startup; `stream_chat` returns SSE for a simple query

---

## T2 — workflow-backend: ChatProxyHandler SSE proxy

### Description
Add a transparent SSE byte-pipe proxy to workflow-backend that forwards frontend chat
traffic to hermes-agent. No event parsing — pure `io.Copy` with Gin's SSE flusher.

New file: `internal/handler/chat_proxy.go` — `ChatProxyHandler` struct with two methods:
- `CreateSession` — proxies `POST /api/workspaces/:wid/features/:fid/chat/session` →
  `POST {HERMES_AGENT_URL}/api/v5/create_session`, forwarding the Authorization header.
- `StreamChat` — proxies `POST /api/workspaces/:wid/features/:fid/chat` →
  `POST {HERMES_AGENT_URL}/api/v5/stream_chat`, injects `workspace_id` + `feature_id`
  into the forwarded body, pipes SSE bytes back via `c.Stream()` + `http.Flusher`.

Register both routes in `cmd/api/api.go`. Inject `HERMES_AGENT_URL` from config.
Promote `gin-contrib/sse` from indirect to direct dep in `go.mod`.

### Required skills
- go-best-practices
- backend-engineer

### Subtasks
- [ ] Create `internal/handler/chat_proxy.go` — `ChatProxyHandler` struct + `CreateSession` + `StreamChat`
- [ ] Register routes in `cmd/api/api.go`: `POST .../chat/session`, `POST .../chat`
- [ ] Add `HERMES_AGENT_URL` to config struct and `.env.template`
- [ ] Promote `github.com/gin-contrib/sse` to direct `require` in `go.mod`
- [ ] Integration test: mock hermes-agent SSE server; assert bytes forwarded unchanged
- [ ] Verify `Content-Type: text/event-stream` is set on proxied response

---

## T3 — digital-factory-ui: right-panel layout + chat UI + SSE client

### Description
Three coordinated changes to digital-factory-ui, all in one task (single repo):

**Layout**: Modify `FeatureSessionPage` to use a horizontal flex split —
`FeatureTabView` on the left (flex-1), `AgentChatPanel` fixed right panel (`w-80`).

**Chat UI components** — new module `src/features/agent-chat/`:
Port from `voyager-interface/src/components/intelligence/agent/agent-elements/`:
- `Conversation` + `ConversationContent` + `ConversationScrollButton`
- `Message` + `MessageContent`
- `MessageThread` (simplified — text + tool_call + loader parts only)
- `PromptInput` / `PromptInputTextarea` / `PromptInputToolbar` / `PromptInputSubmit`
- `Loader`
- `AgentChatPanel` — top-level panel component managing session lifecycle + state

**SSE client** — new file `src/services/workflow-backend/chat.ts`:
- `createChatSession(workspaceId, featureId, userId)` → `POST .../chat/session`
- `streamChatTurn(params, onEvent, onDone, onError)` → `fetchEventSource POST .../chat`
  using `@microsoft/fetch-event-source`

Add `@microsoft/fetch-event-source` to `package.json`.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices

### Subtasks
- [ ] Add `@microsoft/fetch-event-source` to `package.json`
- [ ] Create `src/services/workflow-backend/chat.ts` — `createChatSession` + `streamChatTurn` + `HermesEvent` union type
- [ ] Port `Conversation` + `ConversationContent` + `ConversationScrollButton` from voyager
- [ ] Port `Message` + `MessageContent` from voyager
- [ ] Port `MessageThread` (text/tool_call/loader parts; drop chart/ui_block parts)
- [ ] Port `PromptInput` / `PromptInputTextarea` / `PromptInputToolbar` / `PromptInputSubmit`
- [ ] Port `Loader`
- [ ] Create `AgentChatPanel` — session create on mount, feed messages + status to `MessageThread`
- [ ] Modify `FeatureSessionPage` — horizontal flex split, `AgentChatPanel` in right `w-80` panel
- [ ] Add `NEXT_PUBLIC_WORKFLOW_API_URL` usage note (no new env var — reuse existing)
- [ ] Test: right panel renders alongside FeatureTabView; mock SSE stream renders messages correctly

---

## T4 — digital-factory-ui: SlashCommandPicker

### Description
Add a slash-command picker popover to the chat input. When the user types `/` as the
first character of a message, a popover appears above `PromptInputTextarea` listing
all available workflow commands. Typing more characters filters the list in real time.
Arrow-key navigation + Enter or click inserts the selected command name into the input.
Escape or deleting the leading `/` dismisses the popover.

New component: `src/features/agent-chat/slash-command-picker.tsx`.
Static command registry (co-located in the same file or a `commands.ts` constant):
- `/write-product-spec`
- `/write-technical-design`
- `/get-feature-state`
- `/get-workspace-context`

`PromptInputTextarea` gets an `onSlashOpen` / `onSlashClose` prop to drive picker
visibility, or the picker is integrated directly into `AgentChatPanel`.

### Required skills
- frontend-engineer
- heroui-react
- typescript-best-practices

### Subtasks
- [ ] Define `COMMANDS` registry (name + hint)
- [ ] Create `SlashCommandPicker` component — popover, filtered list, keyboard nav
- [ ] Wire `SlashCommandPicker` into `AgentChatPanel` — show on `/`, hide on Escape/backspace past `/`
- [ ] Insert selected command into textarea value on Enter / click
- [ ] Test: typing `/wri` shows only the two write commands; Enter inserts; Escape dismisses

---

## T5 — hermes-agent: write tools + artifact_saved event

### Description
Extend `workflow_plugin/` (built in T1) with two write tools:
- `workflow_write_product_spec` — GitHub Contents API `PUT /repos/{owner}/{repo}/contents/docs/features/{id}/product-spec.md` using `GITHUB_TOKEN`
- `workflow_write_technical_design` — same, `technical-design.md`

Both tools resolve the management repo `owner/repo` from the workspace record (available
via `workflow_get_workspace_context`). After a successful write, the streaming layer in
`workflow_gateway/streaming/` emits an `artifact_saved` SSE event before the turn-end
`usage` event.

Update `workflow_plugin/plugin.yaml` `provides_tools` list. Add `GITHUB_TOKEN` to
`.env.example` with a note about required `contents:write` scope.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Implement `handle_write_product_spec` in `workflow_plugin/tools.py` — GitHub Contents API PUT
- [ ] Implement `handle_write_technical_design` — same pattern, `technical-design.md` path
- [ ] Add both tools to `_TOOLS` tuple and `register(ctx)` in `workflow_plugin/__init__.py`
- [ ] Update `workflow_plugin/plugin.yaml` `provides_tools` list
- [ ] Add `artifact_saved` event emission in `workflow_gateway/streaming/__init__.py` after write-tool result
- [ ] Add `GITHUB_TOKEN` to `.env.example` with scope note
- [ ] Unit tests: mock GitHub API responses; assert correct PUT payload; assert `artifact_saved` event emitted

---

## T6 — digital-factory-ui: artifact_saved handler + document refresh

### Description
Wire the `artifact_saved` SSE event (emitted by T5) to trigger a live refresh of the
`FeatureTabView` document panels.

`AgentChatPanel` (built in T3) receives an `onArtifactSaved` prop. When `streamChatTurn`
fires an `artifact_saved` event, `AgentChatPanel` calls `onArtifactSaved({ artifact })`.

`FeatureSessionPage` implements `handleArtifactSaved` and calls `reload()` on the
`useFeatureDetail` hook — already available via `FeatureTabView`'s data-fetch pattern.
The saved product spec or technical design appears in the corresponding tab without a
page reload.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `onArtifactSaved` prop to `AgentChatPanel`; fire it on `artifact_saved` event in `streamChatTurn`
- [ ] Implement `handleArtifactSaved` in `FeatureSessionPage`; call `useFeatureDetail` reload
- [ ] Verify `useFeatureDetail` exposes a `reload()` / refetch function; expose if not
- [ ] Test: mock SSE stream emits `artifact_saved`; assert `FeatureTabView` re-fetches feature detail
