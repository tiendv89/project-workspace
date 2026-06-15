# Technical Design

## Feature
- Feature ID: `m3-agent-chat-v4`
- Title: Agent Chat v4 — The Thread: Team Chat, Channels, @mention, and a Triggered Agent

> **Current state verified against live code on 2026-06-14** (branch `main` of `hermes-agent`,
> `workflow-bff`, `workflow-backend`, `digital-factory-ui`, `user-service`, all present locally).
> Findings below cite real paths + symbols. RAG/GitNexus MCP were not in this session, so the
> rag-context pre-flight degraded gracefully (no snippets injected). This design builds on the
> v3 design (`m3-agent-chat-v3/technical-design.md`), which is largely shipped — its
> `ApprovalCard` / `DocumentEditCard` tool-card registry, `stageTransition`, and `listTools`
> already exist in the FE.

---

## 1. Current State

### The conversation domain lives entirely in hermes-agent
hermes-agent owns sessions **and** messages in its own Postgres (async SQLAlchemy + asyncpg;
`DATABASE_URL`). There is no separate chat service.

- **`sessions`** (`migrations/001_initial_schema.sql:5-44`, `src/db/models.py:12-57`): single-owner
  conversations. Columns include `id`, `source`, **`user_id` (one owner)**, `workspace_id`,
  `feature_id` (NOT NULL DEFAULT `''`), `model`, `system_prompt`, `title`, `archived`,
  `is_active`, `last_active_at`, counters (`message_count`, `tool_call_count`, token/cost fields),
  and `metadata` (JSONB). **No member set; no channel concept.**
- **`messages`** (`migrations/001_initial_schema.sql:46-69`, `src/db/models.py:60-85`): `id`,
  `session_id` (FK, CASCADE), **`role` ∈ {user, assistant, tool, system}** — the OpenAI message
  role, **not a human identity** — `content`, `tool_calls`, `tool_call_id`, `tool_name`,
  `finish_reason`, `observed`, `active`, `created_at`. **No `author_id`; no mentions.**

### Chat is request-scoped, and the agent is always invoked
- Routes under `/api/v1` (`src/api/router.py`): `POST /session`, `GET /sessions` (by
  `workspace_id`+`feature_id`, newest-first, non-archived), `GET /sessions/{id}/messages`,
  `POST /chat` (SSE) (`src/api/routers/{sessions,chat}.py`).
- `POST /chat` (`src/api/routers/chat.py:146-229`) = **one agent turn per request**. It guards
  against a concurrent turn on the same session via an in-process `_active_runs` set (409 if a
  turn is already running), loads history, then runs the bundled agent on a worker thread
  (`_run_agent_turn`, lines 63-143). **Every user message triggers an agent response — there is
  no @mention gate.** The agent's bundled `run_conversation()` persists both the user and
  assistant messages via a `GatewaySessionDB` proxy. The SSE response (OpenAI-compatible
  `chat.completion.chunk` + `hermes.tool.progress` + `hermes.artifact.saved`,
  `src/streaming/sse.py`) streams **only to the calling client** — there is no fan-out to other
  viewers.
- **Identity** (`src/api/identity.py:23-49`): `require_identity` trusts BFF-injected `X-User-Id` /
  `X-Org-Id` behind a `GATEWAY_SERVICE_TOKEN` bearer check. New routes inherit this for free.

### The BFF proxies SSE but blocks WebSocket
`workflow-bff` (Go/Gin) is a generic longest-prefix proxy
(`internal/app/api/handler/proxy/{routing.go,proxy_handler.go}`; prefixes in
`configs/config.yaml`: `/bff/hermes-agent`, `/bff/workflow-backend`, `/bff/user-service`).
- **SSE: fully supported** — `text/event-stream` responses are flushed per read with the write
  deadline cleared (`proxy_handler.go:164-207`). New SSE routes work through it with **zero BFF
  change**.
- **WebSocket: rejected** — `isWebSocketUpgrade()` returns **HTTP 501 Not Implemented**
  (`proxy_handler.go:75-77,229-230`). No hijack, no `gorilla/websocket`. **WS would require new
  BFF code.** *This single fact drives the transport decision (§3.1).*
- **Identity injection** (`proxy_handler.go:92-101,139-146`): session cookie → Redis → injects
  `Authorization: Bearer <internal>`, `X-User-Id`, `X-Org-Id`, `X-Accessible-Org-Ids`; browser
  Cookie/Authorization are never forwarded. **It does not inject a workspace role** (relevant to
  channel-admin gating — §3.6).

### workflow-backend and user-service
- `workflow-backend` (Go/Gin/pgx) is read-only feature/task state + (v3) the document view API;
  `RequireBFFIdentity` on `/api/*`. It does **not** own any chat data.
- `user-service` is the identity provider behind `/bff/user-service`. Whether it exposes
  *list-workspace-members* and *caller-workspace-role* endpoints must be verified (§5, T5) — they
  are needed for the `@mention` typeahead and the channel-admin gate.

### Frontend — 1:1 chat, no author, no mentions, no channels
- `src/components/agent-chat/agent-chat-panel.tsx` streams via `@microsoft/fetch-event-source`
  POSTing `${BFF}/bff/hermes-agent/api/v1/chat` (`src/services/hermes-agent/chat.ts:127-172`).
- `message.tsx:59-87` + `types.ts:3-8`: `HermesMessage = {id, role: "user"|"assistant", content,
  toolCalls}` — **no author/avatar/timestamp.** User right-bubble, assistant left.
- `message-thread.tsx` renders tool calls via `ToolCallRow`, with v3's **`ApprovalCard`** and
  **`DocumentEditCard`** already special-cased (`tool-cards/`).
- `prompt-input.tsx` is a plain `<textarea>` with a `/` **SlashCommandPicker** (live `listTools`);
  **no `@mention` typeahead.**
- `feature-workbench.tsx` (3-panel IDE): left explorer has a **Sessions** section
  (`listChatSessions(workspaceId, featureId)`); the active session is held in an `activeChannel`
  state field (naming coincidence — *not* the channels feature). NavRail
  (`shell/nav-rail.tsx:17-21`) routes `/board /feature /tasks /settings` — **no Channels nav.**
- **Confirmed absent everywhere:** member sets, `@mentions`, channels, WebSockets, presence,
  pub/sub, per-message authorship, real-time multi-viewer delivery.

---

## 2. Problem Framing

### What must change
1. **Conversations gain members and authorship.** Sessions must carry an explicit member set;
   messages must record **who** sent them (human author or the agent). (G1, G5)
2. **A message-send path distinct from an agent turn.** Today POST = agent turn. v4 must let a
   human post a message that is persisted and broadcast to all members **without** invoking the
   agent, and invoke the agent **only** when it is `@mentioned`. (G2, G3)
3. **Real-time multi-viewer delivery.** Messages, agent output, and indicators must fan out to
   every member viewing a thread — not just stream back to one caller. (G4)
4. **`@mention` end to end.** Parse/resolve mentions, persist them, drive the agent trigger and
   the in-app mention indicator; render a typeahead and mention tokens. (G2, G6)
5. **Workspace-level Channels.** Named, admin-managed, public conversation spaces not tied to a
   feature, reusing the same conversation machinery; a Channels nav section. (G10, G11)
6. **Workspace-level team threads.** A `feature_id`-less, membership-scoped thread that can be
   created at the workspace level (not only inside a feature), distinct from a named public
   channel, reusing the same conversation machinery; a workspace **Team Chat** nav entry. (G12)

### What must stay stable (verified, reused)
- The **BFF** generic proxy + SSE pass-through + identity injection — **no BFF change** (SSE
  transport only; §3.1).
- The **agent run core** (`run_conversation`, the SSE translator, tool registry, v3 authoring /
  approval tools, `hermes.artifact.saved`) — reused; v4 changes *when* it runs and *where its
  output goes*, not the agent itself.
- The **v3 tool-card registry** (`ApprovalCard` / `DocumentEditCard`) and stage-transition /
  document pipeline — reused unchanged inside feature threads (G8); inert in channels (NG12,
  because authoring/approval tools require a `feature_id`, which channels lack).
- `require_identity` / `RequireBFFIdentity` — new routes inherit auth + `X-User-Id`.

### Fixed assumptions
- **hermes runs single-instance per workspace** (the M2 "resident teammate on a VM" model). This
  makes **in-process pub/sub** sufficient for fan-out (§3.3) — no Redis required for v4.
- `X-User-Id` is the authoritative author/actor identity for a human message (as in v3).
- The agent is addressed as **`@agent`** (product-spec OQ4 resolved) and is an implicit member of
  every conversation.
- Channels are **public**: any workspace member may join/post and **create**; **only admins may
  delete** (product-spec G11). The admin-role source (for delete) is a dependency (§3.6 / §5).

---

## 3. Options Considered

### 3.1 Real-time transport (G4) — **decisive, because the BFF blocks WS**
**Option A — Persistent SSE subscription + plain POST to send (chosen).** A long-lived
`GET …/threads/{id}/stream` (SSE) per viewer delivers all thread events; a separate
`POST …/threads/{id}/messages` sends. Client→server is ordinary POST; server→client is SSE.
- Pros: **reuses the BFF SSE pass-through verbatim — zero BFF change**; reuses the existing SSE
  envelope + `@microsoft/fetch-event-source` on the FE; one well-understood streaming mechanism.
- Cons: two connections (a stream + sends) instead of one duplex socket; SSE is one-directional
  (fine — sends are infrequent POSTs).
- **Chosen.**

**Option B — WebSocket.** Rejected: `workflow-bff` returns **501** on WS upgrade
(`proxy_handler.go:75-77`); adopting WS means ~200 lines of new BFF upgrade/hijack/byte-proxy
code (or routing WS around the BFF, losing identity injection) for a duplex channel v4 does not
need. Revisit only if a future feature needs true bidirectional low-latency.

**Option C — Polling.** Rejected: not real-time (G4); wasteful at the cadence chat needs.

### 3.2 Where the team-chat domain lives
**Option A — extend hermes-agent as the conversation backend (chosen).** Members, message
authorship, mentions, channels, and SSE fan-out are added to hermes, which already owns sessions
+ messages + the agent + the v3 chat surface.
- Pros: **most additive** — one store, one service for the whole conversation domain; the agent
  turn already lives here, so the @mention trigger gate is a local change; single-instance-per-
  workspace makes fan-out trivial (§3.3); no cross-service message plumbing.
- Cons: the agent *service* now also hosts human-to-human realtime chat + channel admin —
  arguably a separation-of-concerns smell. Mitigated: this is the *conversation substrate*, not
  "the hands" (code execution stays in the per-task executor, per the M2 model). If separation is
  later wanted, the domain can move behind the same HTTP contracts with no FE change.
- **Chosen.**

**Option B — own the team-chat domain in workflow-backend (Go); hermes becomes a participant it
invokes.** Cleaner separation and Go is strong at SSE fan-out, but messages live in hermes today
— this means migrating the message store (or splitting it) plus a new internal hermes-invoke API:
a large, non-additive change. **Rejected for v4** (sensible long-term if chat must scale
independently of the agent).

**Option C — a new dedicated chat/realtime service.** Cleanest boundary, most infra/work; over-
built for v4. **Rejected.**

### 3.3 Pub/sub backing for SSE fan-out
**Option A — in-process asyncio pub/sub (chosen).** A per-thread in-memory topic; each
`…/stream` subscriber gets an `asyncio.Queue`; the message-send path and the agent turn publish
to the topic. Justified because **hermes is single-instance per workspace** (§2 fixed
assumptions), so every member of a workspace's threads is connected to the same process.
- Pros: zero new infra; lowest latency; simplest.
- Cons: breaks if hermes is ever horizontally scaled (multiple replicas wouldn't share the topic);
  events buffered in memory only (a dropped connection misses events between reconnects — handled
  by a since-cursor replay from the DB, §4.3).
- **Chosen for v4.** If horizontal scale arrives, swap the topic for **Postgres `LISTEN/NOTIFY`**
  (already have Postgres) or Redis pub/sub behind the same interface. Flagged OQ1.

### 3.4 Channel data model
**Option A — a channel IS a `sessions` row with a `kind` discriminator; no separate table
(chosen).** A channel is a `sessions` row with `kind = 'channel'` and `feature_id = ''`. The
existing columns already cover a channel: `workspace_id` (scope), `title` (name), `user_id`
(creator), `started_at` (created-at), `metadata` (description). Channel **deletion is a hard
delete** of the session row (messages cascade via the `messages.session_id` FK) — resolved OQ2.
Members, messages, mentions, SSE fan-out, and the agent dispatch are then **identical** for
feature threads and channels — keyed by session id.
- Pros: maximal reuse + **no new `channels` table and no second row per channel**; the agent works
  in channels via the same code; NG12 (no feature authoring in channels) is enforced *for free*
  because the authoring/approval tools require a non-empty `feature_id`. Name uniqueness is a
  partial unique index `UNIQUE(workspace_id, lower(title)) WHERE kind='channel' AND NOT archived`.
- Cons: `sessions` becomes explicitly polymorphic (`kind ∈ {thread, channel}`) — but it already is
  implicitly (feature thread vs not), and the `kind` column makes that honest.
- **Chosen.** A dedicated `channels` table was considered and **rejected** — at 1:1
  conversation-per-channel with only name + create/delete (NG5/NG13: no sub-threads, categories,
  or rich per-channel settings), a separate table + `channel_id` join is two rows for one logical
  thing and earns nothing. Revisit only if a channel later contains many threads or gains
  independent settings. (Also rejected: separate channel-message tables; polymorphic
  `conversation_id` on the hot `messages` table.)

### 3.5 The `@mention` trigger gate (G3 — the guardrail)
**Option A — split send-vs-turn; gate at message-send (chosen).** `POST …/messages` always
persists + broadcasts the human message; it invokes an agent turn **only if** the resolved
mentions include `@agent`. Human-to-human messages never reach `run_conversation`.
- Pros: the guardrail is **enforced server-side by construction** — the agent cannot self-dispatch
  from chatter; humans talk freely. Clean audit (mention → trigger).
- **Chosen.** (B: keep "always invoke" and let the agent decide whether to respond — rejected:
  hands the trigger decision to the LLM, violating "triggered, never self-dispatching"; also wakes
  the agent on every human message — noise + cost.)

### 3.6 Admin-role source for channel **deletion** (G11)
Channel **creation is open to any workspace member** — no role check. Only **deletion** is
admin-gated. The BFF injects `X-User-Id`/`X-Org-Id` but **not a role** (§1). Three ways to gate
the delete:
- **Option A — hermes queries user-service for the caller's workspace role (chosen, pending
  endpoint verification).** The delete path calls user-service (server-to-server) to confirm the
  caller is a workspace admin. Authoritative; no BFF change. Requires a user-service role endpoint
  (T5; verify-then-implement-gap).
- **Option B — BFF injects an `X-Workspace-Role` claim.** One lookup, cached at the edge; but adds
  BFF + session-model change (more surface) and couples the BFF to the roles model.
- **Option C — org-owner heuristic.** Rejected — conflates org ownership with workspace admin and
  hard-codes a policy that belongs in the identity model.
- **Chosen: A**, with the exact role semantics and endpoint confirmed in T5 (§5, OQ2).

### 3.7 Message attribution (G5)
**Option A — add `author_id` (TEXT) to `messages` (chosen).** Human messages store the sender's
`X-User-Id`; assistant messages store the agent sentinel; `role` keeps its OpenAI meaning for the
LLM history. Display name/avatar are resolved at read time from user-service (batch) and cached.
- Pros: minimal schema change; `role` semantics preserved for `run_conversation`; one column.
- **Chosen.** (B: a participant-message mapping table — rejected, over-modeled for a 1:N author.)

---

## 4. Chosen Design

**Summary:** extend hermes-agent into the team-chat backend — add membership, message authorship,
mentions, channels, a `@agent`-gated dispatch, and an **in-process pub/sub + per-viewer SSE
subscription** for real-time fan-out — and rebuild the FE chat surface around a persistent
subscription with attribution, an `@mention` composer, member management, and a Channels section.
The BFF is untouched (SSE only); `workflow-backend` is untouched; `user-service` gains member/role
reads if missing.

### 4.1 hermes-agent — data model + store [T1]
New migration + models (additive; no change to existing columns):
- **`session_members`** — `(session_id FK, user_id, role_label NULL, added_by, added_at)`, PK
  `(session_id, user_id)`. The agent is an implicit member (not stored) or a sentinel row; chosen:
  implicit (dispatch + attribution use the sentinel id `agent`).
- **`messages.author_id`** (TEXT, nullable for legacy rows) — sender `X-User-Id`, or the `agent`
  sentinel for assistant messages (§3.7).
- **`message_mentions`** — `(id, message_id FK, session_id, mentioned_id, mentioned_kind ∈
  {user, agent}, read_at NULL)`. Drives the agent trigger (any row with `mentioned_kind=agent`)
  and the per-user unread indicator (`read_at IS NULL` for `mentioned_id = X-User-Id`).
- **`sessions.kind`** (TEXT, NOT NULL DEFAULT `'thread'`, values `'thread' | 'channel'`) — the
  channel discriminator (§3.4). **No separate `channels` table.** A channel is a `sessions` row
  with `kind='channel'`, `feature_id=''`, `title`=name, `user_id`=creator; description lives in
  `metadata` (or a small nullable `description` column). Name uniqueness:
  `UNIQUE(workspace_id, lower(title)) WHERE kind='channel' AND NOT archived` (OQ2).
Store functions: add/remove/list members; member-scoped session listing (own ∪ member-of, G7);
create channel (a `kind='channel'` session) / **hard-delete** (removes the channel session;
messages cascade via the existing `messages.session_id` ON DELETE CASCADE); resolve mentions;
unread-mention count.

### 4.2 hermes-agent — mentions + `@agent`-gated dispatch + send service [T2]
- **Mention parse/resolve.** On send, extract `@…` tokens; resolve against the thread's members
  (by **unique handle/username** from user-service — the display name is shown but the handle
  disambiguates two members with the same name) and the `@agent` sentinel. Persist
  `message_mentions`.
- **Send service** decoupled from the agent turn: persist the human message (`author_id =
  X-User-Id`), publish a `message.created` event to the thread topic (§4.3), then **gate**:
  - **Trigger rule (resolved):** an **explicit `@agent` mention only** triggers a turn; a plain
    reply to an agent message does **not** re-trigger it.
  - **Bare-message default by container (resolved):** in a **feature thread**, a bare message (no
    `@agent`) is treated as an implicit `@agent` (preserves the v3 1:1 feel); in a **channel**, a
    bare message **never** triggers the agent (humans talk; `@agent` is explicit).
  - **Coalescing (resolved):** agent turns are serialized per session by `_active_runs`; multiple
    `@agent` mentions arriving while a turn is in flight **coalesce into one** follow-up turn with
    the combined context, not N competing turns.
- **Agent context by container (OQ8 / NG12).** The dispatch builds the agent's context from the
  conversation, **keyed on `feature_id` presence — not on `kind`**: a session **with** a
  `feature_id` (a feature thread) keeps the full v3 behaviour (feature state, authoring/approval
  tools active); a **feature-less** session (`feature_id=''` — a **channel or a workspace-level
  thread**, §4.10) gets workspace-scoped context only, and the feature-authoring/approval tools
  are **inert** because they require a `feature_id`. No new guard needed — the absence of
  `feature_id` is the guard. The same `feature_id`-keyed rule governs the **bare-message
  default**: a bare message triggers the agent in a feature thread but never in a feature-less
  session (channel or workspace thread).

### 4.3 hermes-agent — real-time transport (SSE fan-out) [T3]
- **In-process pub/sub** (`src/realtime/bus.py`, new): per-thread topic; `subscribe()` returns an
  `asyncio.Queue`; `publish(thread_id, event)` fans out to all subscriber queues (§3.3).
- **`GET /api/v1/threads/{id}/stream`** (SSE, `require_identity`, member-only): registers a
  subscriber and relays events — `message.created` (any author), agent token deltas +
  `hermes.tool.progress` + `hermes.artifact.saved`, `member.changed`, `channel.deleted`, and
  ephemeral `typing`/`agent.working`. A `?since=<message_id|cursor>` replays missed persisted
  messages from
  the DB on (re)connect before live tailing (covers the in-memory-only gap, §3.3).
- **`POST /api/v1/threads/{id}/messages`** (the §4.2 send service) — returns `202` quickly, not a
  stream.
- **`POST /api/v1/threads/{id}/typing`** — ephemeral; published, not persisted.
- **Agent output republish:** the agent turn (reusing `run_conversation` + the SSE translator)
  publishes its frames to the **thread topic** instead of writing only to the caller's response,
  so **all** subscribers see the agent work live. The legacy `POST /chat` is refactored to route
  through this path, with a thin single-subscriber `/chat` shim kept during the FE migration.

### 4.4 hermes-agent — channels API [T4]
Routes under `/api/v1` (`require_identity`). A channel is a `kind='channel'` session (§3.4/§4.1):
- `GET /channels?workspace_id=` → list `kind='channel'`, non-archived sessions (any member).
- `POST /channels {workspace_id, name, description?}` → **open to any workspace member** (no role
  check): create a session with `kind='channel'`, `feature_id=''`, `title`=name; creator
  auto-joined as a member.
- `DELETE /channels/{id}` → **admin-gated** (§3.6): verify the caller is a workspace admin via
  user-service (T5); **hard-delete** the channel session (its messages cascade via the
  `messages.session_id` FK); publish a `channel.deleted` event so live viewers update.
- `POST /channels/{id}/join` → any workspace member joins (adds a `session_members` row).
The conversation inside a channel uses the **same** member/message/mention/stream/dispatch code
(T1–T3) — no channel-specific messaging.

### 4.5 user-service — workspace members + caller role [T5]
Verify, then implement only the gaps:
- **List workspace members** `(user_id, display_name, avatar_url, role)` — for the `@mention`
  typeahead, member-add picker, and read-time attribution resolution.
- **Caller's workspace role** (or a membership-with-role lookup) — for the channel **delete**
  admin gate (§3.6); creation needs no role check. Define what "admin" is here (OQ2). Reuses the
  existing `/bff/user-service` identity surface.

### 4.6 digital-factory-ui — realtime transport + attribution [T6]
- Replace the per-turn `streamChatTurn` with a **persistent subscription**: open
  `GET …/threads/{id}/stream` via `@microsoft/fetch-event-source` on thread open; send via
  `POST …/threads/{id}/messages`. Reconnect with `?since=` for replay.
- Extend `HermesMessage` (`types.ts`) with `author {id, name, avatarUrl, roleLabel}` and render
  attribution in `message.tsx` (human name/avatar; the agent clearly marked). Agent output arrives
  on the same stream as `assistant` deltas attributed to `@agent`.
- v3's `ApprovalCard` / `DocumentEditCard` continue to render in **feature** threads.

### 4.7 digital-factory-ui — `@mention` composer + indicators [T7]
- Add an `@` **typeahead** to `prompt-input.tsx` (alongside the existing `/` slash picker) listing
  thread members + `@agent` (members from T5/T1); insert a resolvable mention token; render tokens
  distinctly in `message.tsx`.
- **In-app mention/unread indicator** driven by `message_mentions.read_at` (T1/T2) — a badge on
  the thread/Channels list and a marker in-thread. **Clear semantics (resolved):** opening a
  thread/channel clears all its unread mentions; each thread/channel shows its own badge, and a
  **workspace-level aggregate count** sits in the nav.

### 4.8 digital-factory-ui — Channels section + membership UI [T8]
- New **Channels** entry in `nav-rail.tsx` + a channel list (workspace-scoped, from T4); opening a
  channel renders the **same** chat surface (T6/T7) bound to the channel's backing thread.
- **Create channel** control available to any member; **delete** control **admin-only**
  (hidden/disabled for non-admins per the role from T5).
- **Member list UI** (view/add/remove) for both feature threads and channels (members from
  T1/T5), with role-label display (G9).

### 4.9 Workspace-level team threads [T9 backend, T10 FE]
A workspace-level thread is the **same `sessions` row** as a feature thread, only without a
feature: `kind='thread'`, `feature_id=''`, `workspace_id` set, `user_id`=creator, `title`=name.
It is distinct from a channel (`kind='channel'`) in exactly one way that matters to users: a
channel is **public** (any workspace member may join/post) while a workspace thread keeps the
feature-thread **explicit-membership** model (only members in `session_members` see and post).
No schema change beyond T1 — the `kind` discriminator and the membership/mention/stream model
already cover it; "feature thread vs feature-less" is read from `feature_id`, "public channel vs
membership thread" from `kind`.

- **hermes-agent [T9]** — building on T1:
  - `POST /api/v1/threads {workspace_id, title?, members?}` → create a `kind='thread'`,
    `feature_id=''` session; creator auto-joined; optional initial members added.
  - Extend the **member-scoped session listing** (T1, G7) so a member's history returns their
    feature threads **and** their workspace-level threads (own ∪ member-of), filterable to the
    workspace-thread set for the Team Chat surface.
  - Conversation, mentions, dispatch, and SSE fan-out (T2/T3) apply **unchanged** — they key on
    session id / `feature_id`, so a workspace thread automatically gets workspace-scoped agent
    context and explicit-`@agent`-only triggering (§4.2). No T2/T3 code change.
- **digital-factory-ui [T10]** — a workspace-level **Team Chat** entry in `nav-rail.tsx`
  (alongside Channels) listing the caller's workspace threads (from T9) and a create-thread
  control; opening one renders the **same** chat surface as feature threads and channels (T6),
  with the `@mention` composer (T7) and member list/add-remove UI (T8). No feature
  authoring/approval affordances render (no `feature_id`).

### 4.10 End-to-end flows
- **Team message:** human A `POST …/messages` → persisted (`author_id=A`) + published →
  B & C see it live on their `…/stream`. No `@agent` ⇒ agent silent (G3).
- **Trigger the agent:** human `@agent …` → send gate detects the agent mention → agent turn runs
  → its deltas + tool progress publish to the topic → **all** members watch it work and see the
  attributed result (G3/G4/G5).
- **Channel:** admin `POST /channels` → members `join` and post on the shared stream; `@agent`
  works with workspace context; feature authoring/approval is inert (NG12).
- **Workspace thread:** member `POST /threads` (no `feature_id`) → adds members → conversation,
  attribution, `@mention`, and real-time fan-out work exactly as a feature thread; `@agent` runs
  with workspace-scoped context; only its members see it (G12, §4.9).

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| BFF forwards new hermes SSE + POST routes with identity, no change | Existing | ✅ generic proxy + SSE pass-through + `X-User-Id` (`proxy_handler.go`) | No — **no BFF change** |
| BFF WebSocket support | Existing | ❌ returns 501 (`proxy_handler.go:75-77`) | **Avoided** — design uses SSE (§3.1) |
| New hermes routes inherit `require_identity` (`X-User-Id`) | Existing | ✅ `src/api/identity.py` | No |
| hermes single-instance per workspace (in-process pub/sub valid) | Assumption (M2 model) | ✅ resolved: in-process for v4; swap to LISTEN/NOTIFY at scale | No for v4 |
| user-service: list workspace members | **Verify/new** | ⚠️ existence unconfirmed | T5 — needed for `@mention` + attribution |
| user-service: caller workspace role (admin gate for delete) | **Verify/new** | ⚠️ existence + "admin" definition unconfirmed | T5 — needed for channel **delete** (§3.6, OQ2) |
| v3 tool-card registry / authoring / approval | Existing (v3) | ✅ `ApprovalCard`/`DocumentEditCard`, `stageTransition`, `listTools` | No — reused in feature threads |
| `@microsoft/fetch-event-source` SSE client | Existing | ✅ `services/hermes-agent/chat.ts` | No — reused for the subscription |
| Postgres (hermes `DATABASE_URL`) for new tables | Existing | ✅ async SQLAlchemy/asyncpg | No — additive migration |
| Concurrent `@agent` mentions / agent-turn serialization | Design detail | reuse `_active_runs`; **coalesce** into one turn; reply does not re-trigger (resolved) | No |

**Unresolved before some tasks can finish:** the exact **user-service member/role endpoints and
the definition of "workspace admin"** (T5) gate the channel-admin path (T4) and the mention
typeahead (T7). T5 is independent and should land early.

---

## 6. Parallelization / Blocking Analysis

Planning view (task **files** are produced in Phase 2 after this design is approved). One repo per
task. Repos touched: **hermes-agent** (backend domain + transport + channels), **user-service**
(member/role reads), **digital-factory-ui** (UI). **workflow-bff and workflow-backend need no
change.**

```
T5: user-service — list workspace members + caller workspace-role endpoints (verify; implement gaps)
  └── Can begin now — no blockers

T1: hermes-agent — data model + store (session_members, messages.author_id, message_mentions,
                   sessions.kind discriminator) + store fns (members, mentions, channel CRUD,
                   member-scoped listing)
  └── Can begin now — additive migration; independent of UI and user-service
  │
  T2: hermes-agent — @mention parse/resolve + @agent-gated dispatch + decoupled send service
  │     └── BLOCKED on T1 (needs author_id + mentions schema + members to resolve against)
  │     │
  │     T3: hermes-agent — realtime SSE fan-out (in-proc pub/sub, GET .../stream, POST .../messages,
  │     │                  typing, agent-output republish, since-replay)
  │     │     └── BLOCKED on T2 (send service publishes the events the stream relays; dispatch
  │     │         output must republish to the topic)
  │     │
  T4: hermes-agent — channels API (member create, admin delete, list, join; channel = kind='channel' session)
        └── BLOCKED on T1 (sessions.kind discriminator + member/store model)
        └── BLOCKED on T5 (delete gate calls user-service for the caller's admin role)

  T6: digital-factory-ui — persistent subscription transport (subscribe/send) + per-message
  │                        attribution rendering
  │     └── BLOCKED on T3 (stream + send contracts) ; needs T1 author field on the read API
  │     │
  │     T7: digital-factory-ui — @mention typeahead composer + mention tokens + unread indicator
  │     │     └── BLOCKED on T2 (mention resolution + unread query)
  │     │     └── BLOCKED on T5 (member list for the typeahead)
  │     │     └── lands after T6 on the FE branch (shared chat surface)
  │     │
  │     T8: digital-factory-ui — Channels nav section + channel list + create (any member) / admin-only delete UI
  │                              + member list/add-remove UI
  │           └── BLOCKED on T4 (channels API) and T5 (members + admin role)
  │           └── lands after T6 on the FE branch (reuses the chat surface)

T9: hermes-agent — workspace-level team threads (kind='thread', feature_id='' create + member-scoped listing)
  └── BLOCKED on T1 (kind discriminator + member/store model); reuses T2/T3 unchanged (keyed on feature_id)

  T10: digital-factory-ui — workspace Team Chat nav entry + workspace-thread list + create; reuses chat surface
        └── BLOCKED on T9 (workspace-thread API) and T6 (shared chat surface); reuses T7/T8 composer + member UI

Waves:
  Wave 1 (parallel): T1, T5                 (hermes schema + user-service reads — independent)
  Wave 2 (parallel): T2, T4, T9             (T2 dep T1; T4 dep T1+T5; T9 dep T1)
  Wave 3:            T3                      (dep T2)
  Wave 4 (parallel): T6, then T7 + T8 + T10 (T6 dep T3; T7 dep T2+T5; T8 dep T4+T5; T10 dep T9+T6; all FE land after T6)
```

---

## 7. Repository Impact

| Repo (`workspace.yaml` id) | Task | Changes | Why |
|---|---|---|---|
| `user-service` | T5 | member-list + caller-role read endpoints (verify, implement gaps) | `@mention` typeahead, attribution, channel-admin gate |
| `hermes-agent` | T1 | migration + models: `session_members`, `messages.author_id`, `message_mentions`, `sessions.kind`; store fns | conversation gains members, authorship, mentions, channels (G1/G5/G10) |
| `hermes-agent` | T2 | mention parse/resolve; decoupled send service; `@agent`-gated dispatch; container-aware agent context | trigger discipline (G3), attribution write, NG12 |
| `hermes-agent` | T3 | `src/realtime/bus.py`; `GET …/threads/{id}/stream`, `POST …/threads/{id}/messages`, `…/typing`; agent-output republish; `?since=` replay | real-time multi-viewer fan-out (G4) over SSE — no BFF change |
| `hermes-agent` | T4 | `GET/POST /channels`, `DELETE /channels/{id}`, `POST /channels/{id}/join`; member-create, admin-gated delete via user-service | public channels; open creation, admin delete (G10/G11) |
| `digital-factory-ui` | T6 | persistent subscription transport (replace per-turn stream); `HermesMessage.author` + `message.tsx` attribution | live shared thread + attribution (G4/G5) |
| `digital-factory-ui` | T7 | `@` typeahead in `prompt-input.tsx`; mention-token rendering; in-app mention/unread indicator | `@mention` UX + indicators (G2/G6) |
| `digital-factory-ui` | T8 | Channels nav + list + admin CRUD UI; member list/add-remove UI with role labels | Channels surface + membership management (G9/G10/G11) |
| `hermes-agent` | T9 | `POST /threads` (create `kind='thread'`, `feature_id=''` session); workspace-thread member-scoped listing | workspace-level team threads (G12) — reuses T1–T3 |
| `digital-factory-ui` | T10 | workspace **Team Chat** nav entry + workspace-thread list + create; reuses the shared chat surface | workspace-level team chat surface (G12) |
| `workflow-bff` | — | **none** (SSE proxied as-is; no WS needed) | — |
| `workflow-backend` | — | **none** (owns no chat data) | — |

---

## 8. Validation and Release Impact

### Testing
- **T1** — migration applies additively; member add/remove/list; member-scoped listing returns
  own ∪ member-of (G7); mention persistence; channel (`kind='channel'` session) creation; unique
  channel name; **hard-delete cascades the channel's messages**.
- **T2** — `@agent` mention ⇒ exactly one agent turn; **human-only message ⇒ zero agent turns**
  (the guardrail — assert no `run_conversation` call); mention resolution incl. unknown handles;
  `author_id` recorded; channel context omits feature tools (NG12).
- **T3** — a message published by one client is received by all `…/stream` subscribers of that
  thread; agent deltas/tool-progress fan out to all members; `?since=` replays missed messages on
  reconnect; non-members are rejected from `…/stream`; typing is ephemeral (not persisted).
- **T4** — any member create ⇒ `kind='channel'` session + creator joined; **non-admin delete ⇒
  403**, admin delete ⇒ channel session + its messages removed (cascade) + emits
  `channel.deleted`; `join` adds membership; unique channel name enforced. Also: a bare message in
  a feature thread triggers the agent, a bare message in a channel does not (resolved OQ4).
- **T5** — member list shape `(id, name, avatar, role)`; caller-role lookup; auth enforced.
- **T6** — subscription opens/reconnects with replay; attribution renders (human vs `@agent`);
  v3 approval/document cards still render in feature threads.
- **T7** — typeahead lists members + `@agent`; tokens render; unread indicator appears for a
  mentioned user and clears on view; **no Slack/email** path exists (in-app only, G6).
- **T8** — Channels nav + list; any member sees create, only admins see delete; member add/remove;
  opening a channel uses the shared chat surface; `@agent` works in a channel.
- **T9** — `POST /threads` creates a `kind='thread'`, `feature_id=''` session with the creator
  joined; the member-scoped listing returns workspace threads (own ∪ member-of) and excludes
  non-members; a workspace thread gets workspace-scoped agent context and explicit-`@agent`-only
  triggering (no feature tools — NG12) with **no T2/T3 change**.
- **T10** — Team Chat nav entry lists the caller's workspace threads; create-thread works; opening
  one renders the shared chat surface with `@mention` + member UI; no feature authoring/approval
  affordances render (no `feature_id`).
- Each repo's full suite + lint/type-check before its PR (CLAUDE.md pre-push): Python (hermes),
  the JS/TS toolchain (digital-factory-ui), and user-service's stack.

### Migration / Config
- **hermes DB migration** (new tables + two nullable columns) — additive, backward-compatible;
  legacy messages have `author_id = NULL` (rendered as the legacy single-user/owner). **No** new
  infra (in-process pub/sub; §3.3). Possible new env: a user-service base URL + service token in
  hermes for the role/member calls (T4/T5) if not already present.
- **No `workspace.yaml`, BFF, or workflow-backend change.**

### Rollout
- Largely additive. The `@agent` gate is **container-aware (resolved OQ4):** in a **feature
  thread** a bare message still invokes the agent (so the v3 single-user UX is unchanged), while
  in a **channel** only an explicit `@agent` invokes it. This means feature-thread behaviour is
  preserved even before the `@` composer (T7) ships.
- Migrate the FE from per-turn `POST /chat` to subscribe+send (T6) in lockstep with T3; keep a
  thin `/chat` shim during the transition.

### Backward compatibility
- Existing sessions/messages remain valid (new columns nullable/defaulted; `sessions.kind`
  defaults to `'thread'`). v3 authoring/approval/PR flows are unchanged inside feature threads.
  The SSE envelope is extended (new event types: `message.created`, `member.changed`, `typing`,
  `agent.working`, `channel.deleted`), not broken.

## Design assets (no Figma)
The product spec contains **no Figma URLs**, so the Figma-link propagation rule does not trigger
(it applies only when the product spec carries Figma links) and the frontend tasks (T6–T8)
require no `### Figma` subsection. If designs are added later, add a `## Figma` section here
mapping each frame to the affected FE tasks, and add a `### Figma` subsection to T6–T8 before
those tasks are marked `ready`.

## Resolved decisions (formerly open questions)
- **OQ1 — Pub/sub at scale → RESOLVED: in-process asyncio for v4.** Justified by the
  single-instance-per-workspace deployment invariant (M2 model). The `bus` interface (§3.3) is
  the seam; if hermes is ever horizontally scaled, swap the implementation for Postgres
  `LISTEN/NOTIFY` (already have Postgres) or Redis with no caller change. No v4 work beyond the
  interface.
- **OQ2 — Admin + deletion → RESOLVED.** "Admin" = the workspace admin/owner role from
  user-service (the exact role id is confirmed in T5 against the m1-identity model). Channel
  deletion is a **hard delete** (channel session row removed; messages cascade via the
  `messages.session_id` FK). Channel name is **unique per workspace** (partial unique index,
  §4.1). An optional seeded `#general` may be created at workspace init; no channel is
  undeletable.
- **OQ3 — Trigger semantics + disambiguation → RESOLVED.** Only an **explicit `@agent`** triggers
  a turn; a plain reply to the agent does **not** re-trigger. Multiple `@agent` mentions during an
  in-flight turn **coalesce into one** follow-up turn (not N turns), serialized by `_active_runs`.
  Human mentions resolve by **unique handle/username** (display name shown; handle disambiguates
  duplicates).
- **OQ4 — Bare-message default + `/chat` migration → RESOLVED.** Container-aware: a bare message in
  a **feature thread** implicitly means `@agent`; in a **channel** a bare message never triggers
  the agent. A thin single-subscriber `/chat` shim is kept during the FE subscribe+send migration,
  then removed.
- **OQ5 — Mention-indicator clear + scope → RESOLVED.** Opening a thread/channel clears **all** its
  unread mentions; each thread/channel shows its own badge; the nav shows a **workspace-level
  aggregate** unread-mention count across threads + channels.
- **Presence → RESOLVED: transient indicators only** (typing / "agent is working"); full
  who's-online presence is out of scope for v4.

No blocking open questions remain. The only deferred detail is the **exact user-service admin role
id**, confirmed during T5 implementation (not a design blocker).

## Reference
- Product spec: `docs/features/m3-agent-chat-v4/product-spec.md`
- Prior design reused: `docs/features/m3-agent-chat-v3/technical-design.md` (BFF proxy, hermes
  gateway, tool-card registry, authoring/approval pipeline)
- Roadmap: `docs/roadmap-milestone.md` → M3 "The Thread" (collaborative chat + real-time
  transport, `@mention`, triggered agent, humans gate) and M2 (single resident hermes per
  workspace — the basis for in-process fan-out).
- Live code verified 2026-06-14:
  - `hermes-agent`: `migrations/001_initial_schema.sql`, `src/db/models.py`,
    `src/api/router.py`, `src/api/routers/{sessions,chat}.py`, `src/api/identity.py`,
    `src/streaming/sse.py`
  - `workflow-bff`: `internal/app/api/handler/proxy/{routing.go,proxy_handler.go}`,
    `configs/config.yaml`
  - `digital-factory-ui`: `src/components/agent-chat/{agent-chat-panel,message,message-thread,
    prompt-input,slash-command-picker,types}.tsx`, `tool-cards/*`,
    `src/services/hermes-agent/chat.ts`, `src/components/features/feature-workbench.tsx`,
    `src/components/shell/nav-rail.tsx`
  - `workflow-backend`: read-only feature state (no chat data); `user-service`: identity provider
    (member/role endpoints to verify)
- Lifecycle + rules: management-repo "no direct push to main", feature-branch rules, and the
  thesis guardrail ("agents are triggered, never self-dispatching") in `CLAUDE.md` /
  `product-thesis.md`.
