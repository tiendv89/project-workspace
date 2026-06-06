# Technical Design

## Feature
- Feature ID: `m3-agent-chat`
- Title: Agent Chat — Conversational Interface for Feature Authoring

---

## 1. Current State

### digital-factory-ui
- Next.js 16.2 (App Router), React 19, TailwindCSS 4, HeroUI v3.
- `FeatureSessionPage` renders a vertical stack: `WorkspaceSessionShell` (header) →
  `FeatureTabView` (tabs: Product Spec / Technical Design / Tasks / Logs).
- `WorkspaceSessionShell` layout: `flex h-screen flex-col`. The children area is
  `flex min-h-0 flex-1 flex-col overflow-hidden` — a full-height column with no
  horizontal split.
- API calls use a thin `fetch`-based `request<T>()` wrapper in
  `src/services/workflow-backend/client.ts`.
- **No SSE/EventSource client code exists anywhere in the codebase.**
- **No chat UI components exist.** voyager (`/Users/pye/code/voyager/voyager-interface`)
  has production-ready chat primitives (`Conversation`, `MessageThread`, `Message`,
  `PromptInput`, `Loader`) that target the same HeroUI + TailwindCSS stack.

### workflow-backend
- Go 1.25, Gin HTTP framework.
- Single handler file (`internal/handler/workspace.go`) wired through a `Service`
  interface. All routes are read-only GETs + a POST `/sync`.
- `gin-contrib/sse v1.1.1` is already in `go.sum` as an indirect dep via Gin — no new
  import needed for SSE primitives.
- **No Anthropic/Claude SDK in `go.mod`.** Must be added.
- **No streaming endpoints.** Every handler calls `response.RespondOK(c, result)` for
  a synchronous JSON response.
- `internal/adapter/rpc.go` calls `workspace-github-adapter` for import/sync. The
  adapter's GitHub client (`workspace-github-adapter/internal/github/client.go`) is
  read-only (GET only). Writes are not exposed via the adapter RPC layer.

### workspace-github-adapter
- Has a GitHub REST API client but only implements GET operations (reads YAML/Markdown
  from a repo tree).
- No file-write (PUT `contents`) operation exists.

### Constraints
- One existing write path to the management repo: the orchestrator (CLI) commits YAML
  and Markdown via git. There is no HTTP-based write path today.
- `GITHUB_TOKEN` is available in the backend environment (used by the orchestrator);
  it can be reused for the chat write tools.
- The product spec requires the write path to go through the workflow skill layer —
  meaning the backend agent must write files into the management repo using the same
  artifact paths the orchestrator uses (`docs/features/<id>/product-spec.md` etc.),
  not a shadow location.

---

## 2. Problem Framing

### What needs to change
1. The layout of the feature view must be split horizontally: existing content on the
   left, a new always-visible chat panel on the right.
2. A chat API endpoint must exist on workflow-backend that accepts a conversation turn,
   calls Claude with workspace context and tool definitions, and streams the response
   back over SSE.
3. The backend must be able to execute tool calls:
   - **Read tools** — pull live workspace and feature context to ground the agent.
   - **Write tools** — write `product-spec.md` / `technical-design.md` to the
     management repo via the GitHub Contents API.
4. The frontend must consume the SSE stream and render messages + a slash-command skill
   picker in the prompt input.

### What must remain stable
- The existing `FeatureTabView` content and all four existing document/task/log panels.
- The workflow lifecycle gates — agent writes draft files; human approves via
  `/approve-feature` unchanged.
- All existing backend routes — the chat endpoint is purely additive.
- The `gin-contrib/sse` usage pattern Gin already knows; no new transport library.

### Fixed assumptions
- Claude Sonnet 4.6 (`claude-sonnet-4-6`) is the agent model for v1, matching
  `workspace.yaml → model_policy.implementation.default`.
- The write tool uses the GitHub REST API (`PUT /repos/{owner}/{repo}/contents/{path}`)
  with `GITHUB_TOKEN` from the backend environment.
- Chat history is in-memory (browser session only). No server-side persistence in this
  slice.

---

## 3. Options Considered

### Option A — Next.js API route + Vercel AI SDK (`useChat`)
The frontend calls a Next.js API route (`/app/api/chat/route.ts`) that uses
`@ai-sdk/anthropic` and streams via the AI SDK protocol.

- **Pros:** Excellent streaming DX with `useChat` hook; minimal backend change.
- **Cons:** `ANTHROPIC_API_KEY` lives in Next.js env (still server-side, but not in
  the Go backend); write tools would need a secondary HTTP call back to workflow-backend
  to execute — two-hop architecture. Inconsistent with "all API calls go through
  workflow-backend" pattern.
- **Dependency impact:** New npm dep, no Go change. Write tools require new HTTP
  endpoints in Go anyway.

### Option B — workflow-backend SSE endpoint + Anthropic Go SDK (chosen)
The frontend POSTs to workflow-backend, which calls Claude with tools and streams SSE
events back. Tool execution (reads + GitHub writes) happens in Go.

- **Pros:** `ANTHROPIC_API_KEY` stays in Go env; write tools have direct access to
  GitHub token and workspace context; consistent single-backend API pattern; `gin-contrib/sse`
  is already in the dep tree.
- **Cons:** Must add Anthropic Go SDK to `go.mod`; slightly more Go code to write.
- **Dependency impact:** One new Go dep (`github.com/anthropics/anthropic-sdk-go`).

### Option C — Direct Claude API calls from frontend (browser)
Browser calls Claude API directly.

- **Cons:** API key exposed to client. Rejected immediately.

**Decision: Option B.** The single-backend pattern is consistent, keys stay in Go,
and tool execution is straightforward without a second hop.

---

## 4. Chosen Design

### Layout change (digital-factory-ui)

`FeatureSessionPage` wraps `FeatureTabView` inside `WorkspaceSessionShell`. The
`WorkspaceSessionShell` children area is a flex column. To add the right panel, the
`FeatureSessionPage` component is modified to render a horizontal flex container:

```
WorkspaceSessionShell
└── <div className="flex min-h-0 flex-1 overflow-hidden">    ← NEW horizontal split
    ├── <div className="flex-1 min-w-0 overflow-hidden">     ← existing content
    │   └── FeatureTabView
    └── <div className="w-80 shrink-0 border-l ...">         ← NEW chat panel
        └── AgentChatPanel
```

The panel width is fixed at `w-80` (320px) for v1 — no resize handle.

### Chat panel UI (digital-factory-ui)

Port the following voyager components into `digital-factory-ui/src/features/agent-chat/`:
- `Conversation` + `ConversationContent` — scrollable container, scroll-to-bottom button.
- `Message` + `MessageContent` — user bubble (right-aligned, bg bubble) vs assistant
  prose (left-aligned, transparent).
- `MessageThread` — iterates messages, renders `MarkdownContent` for text parts,
  a `Loader` spinner while streaming.
- `PromptInput` + `PromptInputTextarea` + `PromptInputSubmit` — auto-resizing textarea,
  Send/Stop button, `Enter` to submit.
- `SlashCommandPicker` — **new component** (not in voyager): appears as a popover above
  the input when the textarea value starts with `/`; filters a static command registry
  as the user types; arrow-key + Enter or click to insert the command. Dismissed on
  Escape or when the leading `/` is removed.

Command registry (static, in frontend):
```ts
const COMMANDS = [
  { name: "/write-product-spec",    hint: "Draft or update the product spec" },
  { name: "/write-technical-design",hint: "Draft or update the technical design" },
  { name: "/get-feature-state",     hint: "Show current feature lifecycle state" },
  { name: "/get-workspace-context", hint: "Show repos, roles, model policy" },
];
```

### SSE streaming client (digital-factory-ui)

A `streamChatTurn(params, onEvent, onDone, onError)` function in
`src/services/workflow-backend/chat.ts` that:
1. POSTs to `POST /api/workspaces/:workspaceId/features/:featureId/chat` with
   `fetch` + `{ body: ..., headers: { Accept: 'text/event-stream' } }`.
2. Reads the response body as a `ReadableStream`, decodes SSE lines.
3. Dispatches typed events to the caller:
   - `delta` — partial assistant text token.
   - `tool_start` / `tool_result` — tool call lifecycle.
   - `artifact_saved` — a write tool completed; carries `{ artifact: "product_spec" | "technical_design" }`.
   - `error` — stream-level error.
   - `done` — stream complete.

No external SSE library — the browser `ReadableStream` + `TextDecoder` is sufficient.

### Backend endpoint (workflow-backend)

New route: `POST /api/workspaces/:workspaceId/features/:featureId/chat`

Request body:
```json
{
  "messages": [
    { "role": "user", "content": "Help me write the product spec for dark mode" }
  ]
}
```

Response: `Content-Type: text/event-stream`

SSE event format (newline-delimited JSON data fields):
```
data: {"type":"delta","text":"Sure, let me draft that for you."}
data: {"type":"tool_start","name":"get_feature_state"}
data: {"type":"tool_result","name":"get_feature_state","result":"..."}
data: {"type":"artifact_saved","artifact":"product_spec"}
data: {"type":"done"}
```

Handler implementation:
1. Extract `workspaceId`, `featureId` from path; parse `messages` from body.
2. Build system prompt with workspace + feature context (call existing
   `svc.GetFeature()` to get live state, format as context string).
3. Call `anthropic.NewClient()` with `ANTHROPIC_API_KEY` from env.
4. Invoke `client.Messages.Stream()` with model, system prompt, messages, and tool defs.
5. Write SSE events as they arrive: `delta` for text chunks, `tool_start` when a tool
   is called, `tool_result` after execution, `done` on completion.
6. On context cancellation (client disconnect), stop the stream.

A new `ChatHandler` struct (separate from `WorkspaceHandler`) is registered on the
same router group. It depends on a `ChatService` interface:

```go
type ChatService interface {
    GetFeatureContext(ctx context.Context, workspaceID, featureID string) (*ChatContext, error)
    WriteArtifact(ctx context.Context, workspaceID, featureID, artifactType, content string) error
}
```

`ChatContext` carries the workspace name, available repos, feature status, and the
content of any already-saved artifacts (product-spec.md, technical-design.md).

### Tool definitions (backend)

Four tools, all executed server-side:

| Tool | Action | Implementation |
|---|---|---|
| `get_workspace_context` | Return workspace metadata | Call `svc.GetWorkspace()` → serialize repos, model_policy, roles |
| `get_feature_state` | Return feature status + existing artifact content | Call `svc.GetFeature()` + fetch raw Markdown from GitHub Contents API |
| `write_product_spec` | Write draft to management repo | GitHub Contents API `PUT /repos/{owner}/{repo}/contents/docs/features/{id}/product-spec.md` |
| `write_technical_design` | Write draft to management repo | Same path, `technical-design.md` |

For the write tools, the backend resolves the management repo's `owner/repo` from the
workspace record (already stored by the adapter) and uses `GITHUB_TOKEN` from env.

The write tool sends an `artifact_saved` SSE event after a successful write. The
frontend handles this by re-fetching the feature detail to refresh the document panel.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| `github.com/anthropics/anthropic-sdk-go` | External Go dep | Not in `go.mod` | Yes — must be added in T1 |
| `ANTHROPIC_API_KEY` | Env var | Not in `.env.template` | Yes — must be added before T1 is testable |
| `GITHUB_TOKEN` | Env var | Already used by orchestrator | No — exists; needs confirming it's in workflow-backend env |
| Management repo `owner/repo` | Workspace record in DB | Already stored by adapter | No — available via `svc.GetWorkspace()` |
| `gin-contrib/sse` | Go dep | Already indirect dep | No — direct import just needs promotion to `require` |
| Voyager chat components | Source reference | Available locally | No — porting task, no external dep |
| HeroUI v3 | npm dep | Already in digital-factory-ui | No |
| Browser `ReadableStream` | Web API | Standard, no dep | No |

**Unresolved at design time:**
- Confirm `ANTHROPIC_API_KEY` is available in the workflow-backend deployment environment
  before T1 can be tested end-to-end. The task can be completed locally; deployment
  validation requires the key.
- Confirm `GITHUB_TOKEN` in workflow-backend env has `contents:write` scope on the
  management repo. The orchestrator uses it for git pushes, not GitHub API writes —
  the token scope may need verifying.

---

## 6. Parallelization / Blocking Analysis

```
T1: workflow-backend — SSE chat endpoint + Anthropic SDK + read tools
  └── Can begin now — no blockers
      (add anthropic-sdk-go dep, implement handler + read tools; write tools deferred to T4)

T2: digital-factory-ui — Right-panel layout + chat UI components + SSE client
  └── Can begin now — no blockers
      (port voyager components; mock SSE stream for local dev until T1 merges)

  T1 and T2 run in parallel (Wave 1)

  T3: digital-factory-ui — Slash-command picker
    └── BLOCKED on T2 (needs PromptInput component in place to extend with picker popover)

  T4: workflow-backend — Write tools (write_product_spec, write_technical_design)
    └── BLOCKED on T1 (must extend the T1 handler's tool-execution loop)

  T3 and T4 run in parallel (Wave 2)

  T5: digital-factory-ui — artifact_saved event handling + document panel auto-refresh
    └── BLOCKED on T2 (streaming client must be in place)
    └── BLOCKED on T4 (artifact_saved SSE event defined and emitted by backend)

  T5 is Wave 3 — both T2 and T4 must be merged first
```

---

## 7. Repository Impact

| Repo | Changes | Why |
|---|---|---|
| `digital-factory-ui` | New `src/features/agent-chat/` module; modify `FeatureSessionPage` for horizontal split; new `src/services/workflow-backend/chat.ts` SSE client | UI components, layout, streaming client |
| `workflow-backend` | New `internal/handler/chat.go`; new `internal/service/chat.go`; add `anthropic-sdk-go` to `go.mod`; new route registered in `cmd/api/api.go` | Backend chat endpoint + tool execution |
| `workspace-github-adapter` | None | Writes bypass the adapter and call GitHub API directly from workflow-backend |
| `management-repo` | None (runtime artifact files are written by the write tools during use) | N/A |

---

## 8. Validation and Release Impact

### Testing
- **T1/T4 (workflow-backend):** Integration test for `POST /chat` endpoint — mock
  Anthropic client, verify SSE event sequence for a read tool call and a write tool call.
  Verify `GITHUB_TOKEN` scope check returns a clear error if write fails.
- **T2/T3/T5 (digital-factory-ui):** Component tests for `SlashCommandPicker`
  (filter logic, keyboard nav); integration test for `streamChatTurn` against a mock
  SSE server.

### Migration / Config
- `ANTHROPIC_API_KEY` must be added to workflow-backend env (deployment + `.env.template`).
- No DB migration required.
- No changes to existing API routes — purely additive.

### Rollout
- The chat panel is rendered inside `FeatureSessionPage` only; it does not appear on
  the board or task views. Rollout is scoped to the feature detail page.
- The backend endpoint is unauthenticated at the route level for v1 (same as other
  existing routes, which rely on session middleware). No new auth surface.

### Backward Compatibility
- No breaking changes. All existing API routes are unchanged. The layout change
  (horizontal split) affects only the feature detail page and is purely additive HTML.
