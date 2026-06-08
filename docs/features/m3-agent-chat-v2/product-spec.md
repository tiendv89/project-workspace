# Product Specification

## Feature
- Feature ID: `m3-agent-chat-v2`
- Title: Agent Chat v2 — Session History, Enriched Context, and IDE-style Layout

## Background

M3 v1 (`m3-agent-chat`) shipped an MVP: a fixed right-side chat panel inside the feature
view that lets a user talk to an agent to draft workspace artifacts. It proved the core
loop — stream a response, call a tool, write a document — but left three significant gaps
explicitly as non-goals:

1. **No session history.** A page refresh wipes the conversation. Users cannot resume
   yesterday's drafting session or compare two lines of exploration.
2. **Shallow agent context.** The agent reads workspace.yaml and raw artifact Markdown from
   GitHub. It has no access to live task status from the database, no code-structural
   awareness via GitNexus, and no semantic recall via RAG. It answers questions about the
   feature's stage but cannot answer "which tasks are blocked?" or "how does this PR
   touch the agent loop?"
3. **Bolt-on layout.** The chat panel is appended to an existing tab view designed for
   single-column document review. The resulting layout does not give the user a coherent
   mental model for simultaneous task tracking, document review, and agent conversation.

v2 closes all three gaps.

## Problem

### Session amnesia
Every conversation starts from zero. A user who spent an hour last week iterating on a
technical design brief cannot pick up where they left off. There is no way to scan past
sessions to recall what the agent suggested or what decisions were made conversationally.
The Postgres session store added in v1 contains the full message history but the UI
never surfaces it.

### Context-blind agent
The agent's `pre_llm_call` hook injects workspace and feature state from static files.
It has no access to:
- Live task status (which tasks are `in_progress`, `blocked`, `done`) from the database.
- Code structure context (symbol definitions, call graphs, blast-radius of a change) from
  GitNexus.
- Semantic search across workspace documents and feature history from the RAG index.

Users frequently ask questions the agent cannot answer well: "Which tasks are still
running?", "What file would I need to change to add a new SSE event type?", "Has
anything similar been done in a previous feature?" These fall through because the agent
lacks the right tools.

### Layout fragmentation
The current UI asks users to context-switch between the feature tab view (document content)
and the chat panel (conversation) while mentally tracking task progress with no visible
indicator. There is no single screen that combines the three information surfaces a user
needs simultaneously: task/feature status, document content, and the agent.

## Goals

- **G1** — The chat panel shows a persistent session history list for the current feature,
  with each session showing its title, date, and a last-message excerpt. Users can select
  any past session to resume it.
- **G2** — When inside an active session, a back button returns the user to the session
  history list. The chat input is always visible; submitting from the history list starts
  a new session, submitting from an active session continues it.
- **G3** — The agent has access to live task data from the workflow-backend database —
  task status, blocked reason, PR URL, execution actor — not just static YAML on disk.
- **G4** — The agent can query GitNexus for code-structural context (symbol lookup, call
  graph, blast-radius analysis) before answering questions that touch implementation.
- **G5** — The agent can query the RAG index for semantic recall across workspace documents,
  feature history, and design artifacts.
- **G6** — The app adopts a three-panel IDE-style layout for the feature view: left panel
  shows task/feature status (Jira-like), center panel shows document content (artifact
  tabs), right panel hosts the agent chat. The feature list entry point is preserved and
  becomes the natural home screen.
- **G7** — The new layout is responsive to narrower viewports by collapsing the left
  panel first, then providing a toggle to collapse the right panel, so the center content
  area is always usable.

## Non-goals

- **NG1** — This feature does not add @mentions, group chat, or multi-actor threads.
- **NG2** — This feature does not add code editing or file diffing to the center panel.
  The center panel is a document viewer, not a code editor.
- **NG3** — This feature does not change the approval flow. The agent drafts; the human
  approves via the existing `approve-feature` mechanic.
- **NG4** — This feature does not add GitNexus or RAG MCP server setup. It assumes both
  MCPs are already reachable from hermes-agent (`GITNEXUS_MCP_URL`, `RAG_MCP_URL` env
  vars). If either is absent at runtime the corresponding tool is silently omitted from
  the agent's tool list.
- **NG5** — This feature does not redesign the workspace home screen or navigation beyond
  confirming the feature list as the entry point.
- **NG6** — This feature does not implement drag-and-drop task reordering or inline task
  editing in the left panel. The left panel is read-only status display for v2.

## User Flows

### Home screen — feature list
The user lands on the workspace home screen, which shows the feature list (unchanged
from today). Clicking a feature row opens the three-panel feature view.

### Three-panel feature view
The feature view is a full-height horizontal split:

```
┌─────────────────┬──────────────────────────────┬───────────────────┐
│  Left panel     │       Center panel            │   Right panel     │
│  (~260 px)      │       (flex-1)                │   (~360 px)       │
│                 │                               │                   │
│  Feature status │  [Product Spec]  [Tech Design]│  Chat sessions /  │
│  Stage badge    │  [Tasks]  [Logs]              │  active chat      │
│  ─────────────  │                               │                   │
│  Task list      │  <artifact content>           │  <message thread> │
│  T1 ● done      │                               │                   │
│  T2 ● in_prog   │                               │  ┌─────────────┐  │
│  T3 ○ todo      │                               │  │  chat input │  │
│  T4 ⊗ blocked   │                               │  └─────────────┘  │
└─────────────────┴──────────────────────────────┴───────────────────┘
```

- Left and right panels are independently collapsible via toggle buttons on their inner
  edges.
- The center panel is never hidden — it is always the fallback visible surface.

### Session history list (right panel — default state)
When the user opens a feature, the right panel shows the session history list:

- Each row: session title (auto-generated from first user message), relative date
  ("2 days ago"), and a one-line excerpt of the last message.
- Sessions are ordered newest-first.
- If no sessions exist, the panel shows an empty state: "No conversations yet."
- A chat input box sits at the bottom. Submitting a message from this state creates a
  new session and immediately transitions to active chat mode.

### Active chat session
After the user selects a session from the list (or submits a new message):

- The panel switches to active chat mode: the full message thread for that session is
  displayed.
- A back arrow (top-left of the right panel) returns to the session history list.
- The session title is shown in the panel header.
- The chat input continues the existing session.

### Agent answers a context-rich question
1. User types: *"Which tasks are currently blocked and why?"*
2. Agent calls `workflow_get_tasks` — queries workflow-backend DB for live task status.
3. Agent returns a summary of blocked tasks with their `blocked_reason` values.
4. User types: *"What file would I need to edit to add a new SSE event type to the chat
   proxy?"*
5. Agent calls `workflow_query_gitnexus` — looks up the `ChatProxyHandler` symbol and
   its call graph in the GitNexus index.
6. Agent answers with the exact file and function to modify.

### Slash-command skill picker (unchanged from v1)
Typing `/` in the chat input opens the skill picker popover. The command list is
extended to include the new context tools.

## Scope

### In scope

**Session history (right panel)**
- Session list view: ordered list of past sessions per feature, title + date + excerpt.
- Active chat view: full message thread + back navigation.
- State machine: `history_list` ↔ `active_chat` toggle driven by session selection and
  back button. Chat input at bottom of right panel in both states, behavior changes by
  state (new vs. continue).
- Session title auto-generated on creation from the first user message (truncated to
  60 chars).
- Sessions loaded from the existing `voyager_sessions_v4` Postgres table via
  workflow-backend (new list endpoint).

**Agent context tools (hermes-agent workflow_plugin)**
- `workflow_get_workspace_context` and `workflow_get_feature_state` — retained unchanged
  from v1. `workflow_get_feature_state` continues to provide feature stage, review status,
  and artifact content (product-spec.md, technical-design.md); it is not replaced by the
  new tools below.
- `workflow_get_tasks` — query the Postgres database directly (asyncpg, same connection
  pool used by the gateway session store) for all tasks in the current feature, returning
  id, title, status, blocked_reason, pr.url, depends_on, execution.actor_type. The agent
  does not call workflow-backend for this — a direct DB query avoids a circular dependency
  between hermes-agent and workflow-backend.
- `workflow_query_gitnexus` — forward a natural-language or structured query to the
  GitNexus MCP (`mcp__gitnexus__query`) and return results. Omitted from tool list if
  `GITNEXUS_MCP_URL` is absent.
- `workflow_query_rag` — forward a query to the RAG MCP (`mcp__rag-server__rag_query`)
  and return top-k results. Omitted from tool list if `RAG_MCP_URL` is absent.
- Update `pre_llm_call` hook to include live task summary (counts by status, any blocked
  tasks) in the system context on every turn.

**Three-panel layout (digital-factory-ui)**
- Replace the existing `FeatureSessionPage` two-column layout with a three-panel shell:
  left status panel, center tab view (artifact content, unchanged), right chat panel.
- **Left panel**: feature stage badge, feature status, ordered task list with status
  icons. Read-only. Collapsible.
- **Right panel**: session history / active chat (see above). Collapsible.
- **Center panel**: existing `FeatureTabView` content area, unchanged — Product Spec,
  Technical Design, Tasks, Logs tabs.
- Responsive: left panel collapses automatically below 1200 px viewport width; right
  panel provides a manual collapse toggle at all widths.
- Collapse state persisted in `localStorage` per user.

**New workflow-backend endpoints**
- `GET /api/workspaces/:workspaceId/features/:featureId/chat/sessions` — list sessions
  for a feature (id, title, created_at, last_message_at, last_message_excerpt).
- `GET /api/workspaces/:workspaceId/tasks?featureId=:featureId` — list tasks from DB
  for the left panel UI. This endpoint is for the frontend only; the agent tool
  `workflow_get_tasks` queries the database directly and does not use this route.

### Out of scope (tracked separately)
- Task breakdown authoring via chat (follow-on).
- Inline task status updates from the left panel.
- Presence indicators or live collaborative editing.
- Notification badges on the chat panel for new agent activity.

## Success Criteria

- A user can open a feature they worked on yesterday and resume the conversation from
  the exact message where they left off, without any copy-paste.
- A user can ask "which tasks are blocked?" and receive an accurate, up-to-date answer
  sourced from the database, not a stale YAML snapshot.
- When `GITNEXUS_MCP_URL` is set, a user can ask a code-structural question ("what
  calls `ChatProxyHandler`?") and get a grounded answer with file + line references.
- The three-panel layout is usable at 1280 px wide: left panel shows task status, center
  shows artifact content, right panel shows the agent chat — all simultaneously without
  horizontal overflow.
- Collapsing the left or right panel gives the center panel the reclaimed width within
  one animation frame; state survives a page refresh.
- Typing `/` in the chat input shows the updated slash-command list including the new
  context tools; selecting one inserts the command correctly.

## Reference
- v1 spec: `docs/features/m3-agent-chat/product-spec.md`
- v1 technical design: `docs/features/m3-agent-chat/technical-design.md`
- Session store schema: `voyager_sessions_v4`, `voyager_messages_v4` (swell-hermes pattern,
  live in hermes-agent Postgres).
- GitNexus MCP tool: `mcp__gitnexus__query` — see `CLAUDE.md` GitNexus lookup priority rule.
- RAG MCP tool: `mcp__rag-server__rag_query` — see `CLAUDE.md` RAG-first read rule.
- Layout reference: VS Code three-panel shell (file explorer | editor | terminal/chat),
  Linear issue detail view (status sidebar + content area).
