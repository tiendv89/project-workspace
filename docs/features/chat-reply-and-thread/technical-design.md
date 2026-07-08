
# Technical Design

## Feature
- Feature ID: `chat-reply-and-thread`
- Title: Message Replies and Threads in Team Chat

## Current State

The team-chat conversation domain lives entirely in `hermes-agent` (async SQLAlchemy /
asyncpg), delivered across `m3-agent-chat-v2` → `v4`. Verified against live code:

- **`sessions`** (`src/db/models.py:Session`) — the container the product spec calls a
  "thread" or "channel" (`kind` = `thread` | `channel` | `dm`). Has an existing, currently
  unused-by-this-feature `parent_session_id` self-FK (nullable) — considered and rejected as
  a mechanism for message threads, see Options.
- **`messages`** (`src/db/models.py:Message`) — flat, append-only per session. Columns
  include `id` (BigInteger PK), `session_id` (FK CASCADE), `role`, `content`, `author_id`
  (added in v4 — sender's user id or `'agent'` sentinel, nullable for legacy rows),
  `cta_suggestions`. **No parent/child linkage between messages at all.**
- **`SessionMember`** (`src/db/models.py`) — explicit per-session membership; no message-level
  membership concept exists or is needed (spec G3 wants thread visibility to just inherit
  session membership).
- **`MessageMention`** — resolved `@mention`s per message, feeds `notification-service` and
  the unread-mention badge. Independent of message parent/child structure.
- **Send path** (`src/api/routers/messages.py:send_message`, `POST
  /threads/{session_id}/messages`): persists the human message via
  `src/db/store.py:append_message`, resolves+persists mentions
  (`src/api/mentions.py:parse_mention_handles/resolve_mentions`, `src/db/store.py:
  persist_mentions`), fans out over the in-process bus (`src/realtime/bus.py:get_bus().publish`)
  as a `message.created` SSE event, then gates agent dispatch via `_should_trigger_agent`
  (explicit `@agent` always triggers; bare message triggers only in `kind='thread'`
  sessions) and calls `src/api/agent_dispatch.py:schedule_agent_turn`. The agent turn itself
  persists its reply via the same `append_message` (`_backfill_assistant`,
  `_run_agent_turn_async`, `_persist_decline`, `_persist_quota_block` in `agent_dispatch.py`
  all call it).
- **Read path** (`GET /threads/{session_id}/messages`, `src/db/store.py:
  get_session_messages` / `get_messages_since`): returns the full flat transcript,
  oldest-first (or since a cursor id), then enriches author display info via
  `src/services/author_resolver.py:attach_authors`.
- **Frontend** (`digital-factory-ui`): `src/components/agent-chat/message-thread.tsx:
  MessageThread` renders the whole conversation feed (this is the *session-level* "thread" —
  potential naming collision, see below); `src/components/agent-chat/message.tsx:Message` /
  `MessageContent` render one message bubble with `AuthorAvatar`/`AuthorLabel` attribution
  (from `m3-agent-chat-v4`/T6). Transport: `subscribeToThread`/`sendThreadMessage`
  (`src/services/hermes-agent/chat.ts`) — persistent SSE subscription with `?since=` replay.
- **Naming collision, confirmed in code, not just the spec's concern:** `digital-factory-ui`
  already has an unrelated `ThreadPanel` (`src/components/tasks/task-review-view.tsx:951-1034`)
  for task-review comment threads, and `MessageThread` names the whole conversation feed.
  This design introduces new, distinctly-named symbols (`MessageRepliesPanel`,
  `ReplyIndicator`) to avoid colliding with either.

## Constraints
- Message threads must be a single flat level (non-goal: no nested threads).
- A message thread's visibility/membership must equal its parent session's — no new
  membership model or invite step (G3).
- Real-time delivery must reuse the existing SSE bus (`get_bus().publish(session_id, ...)`)
  — no new transport (G4).
- The agent must remain triggered-only; replies/threads must not create a new
  self-dispatch path (G5).
- Changes must be additive/backward-compatible: existing rows have no reply/thread linkage
  and must keep rendering exactly as today.
- G6 (reply-without-mention notification) is an **open product question** — the design must
  not hard-wire a decision; it should leave an explicit, inert extension point.

## Options Considered

### Option A — New `message_replies` / `message_threads` table(s), separate from `messages`
- Pros: keeps the hot `messages` table narrow; clean conceptual separation between
  "top-level messages" and "thread replies."
- Cons: duplicates most of the message pipeline (author attribution, `@mention` parsing/
  persistence, agent-turn persistence, SSE payload shape) across two storage paths that must
  stay in sync; `agent_dispatch.py`'s four `append_message` call sites, `author_resolver.py`,
  and `mentions.py` would all need thread-table-aware branches. Highest implementation and
  ongoing-maintenance cost for the least gain given threads are flat (no recursive structure
  to justify a separate table).

### Option B — Model a message thread as a child `Session` via the existing `parent_session_id` FK
- Pros: `parent_session_id` already exists on `sessions`, unused; would reuse the entire
  session/message/membership/SSE-per-session infra with zero new `messages` columns.
- Cons: a `Session` row carries a lot of irrelevant weight for a reply chain (model,
  token/cost counters, `SessionMember` rows that would need to be auto-copied from the
  parent at creation time to satisfy G3, its own SSE channel requiring a second subscription
  per open thread panel). Materially more surface area and moving parts than a flat reply
  chain needs, and it does not naturally give "reply to a message in the main transcript"
  (G1) without inventing a one-message-long child session for every inline reply.

### Option C — Add nullable `reply_to_message_id` / `thread_root_id` columns directly on `messages` (chosen)
- Pros: reuses 100% of the existing message pipeline — author attribution, `@mention`
  persistence, agent-turn persistence (`append_message` already threads through every write
  path), and the existing per-session SSE channel — as purely additive, nullable columns.
  Matches the "flat, single level" constraint exactly (no self-referential depth beyond one).
  Legacy rows are unaffected (`NULL` on both columns, same as `author_id`'s v4 rollout).
- Cons: main-transcript read queries (`get_session_messages`, `get_messages_since`) must add
  a `thread_root_id IS NULL` filter at a small number of call sites; `messages` gains two
  more nullable columns.

**Decision: Option C.** It is the minimal-surface-area change that satisfies G1–G5 by
extending the one pipeline every message (human or agent) already flows through.

## Chosen Design

### Data model (hermes-agent, new migration)
Add to `messages` (`src/db/models.py:Message`):
- `reply_to_message_id: BigInteger, ForeignKey("messages.id"), nullable` — set whenever this
  message is posted as a direct reply to another specific message (G1). Used purely for
  rendering the quoted parent preview; does **not** by itself move the message out of the
  main transcript.
- `thread_root_id: BigInteger, ForeignKey("messages.id"), nullable` — set whenever this
  message lives inside a **message thread** rooted at another message (G2). `NULL` = the
  message renders in the main transcript (the common case, including plain G1 replies).
  Non-`NULL` = the message is scoped to the thread rooted at that id and is excluded from
  the main transcript.
- A message posted as a reply *inside* an already-open thread sets **both**: `
  thread_root_id` = the thread's root, and `reply_to_message_id` = whichever message it is
  visually replying to within that thread (defaults to the root on the first reply).
- Indexes: `idx_messages_thread_root (session_id, thread_root_id, created_at)` (fetch a
  thread's replies), `idx_messages_reply_to (reply_to_message_id)` (render quoted-parent
  lookups). A thread root itself always has `thread_root_id IS NULL` — "is this message a
  thread root" is derived (reply count > 0), not a stored flag, so no separate migration
  is needed when the first reply is posted.
- Constraint (app-level, not DB): a message whose `thread_root_id` is already non-`NULL`
  cannot itself become a `thread_root_id` target for another message (enforces the
  single-flat-level non-goal). Enforced in the new endpoint below with a 400.

### API (hermes-agent, `src/api/routers/messages.py` + new `message_threads.py`)
- `SendMessageRequest` (existing `POST /threads/{session_id}/messages`) gains an optional
  `reply_to_message_id: Optional[str] = None` — supports G1 (plain inline reply, main
  transcript, `thread_root_id` stays `NULL`).
- New `src/api/routers/message_threads.py`:
  - `POST /threads/{session_id}/messages/{message_id}/replies` — post into the message
    thread rooted at `message_id` (G2). Body: `{content, model?}`. Validates `message_id`'s
    own `thread_root_id IS NULL` (else 400 `nested_thread_not_supported`); sets
    `thread_root_id = message_id` on the new row (or, if the caller replies to a specific
    reply within the panel, still `thread_root_id = message_id`, with `reply_to_message_id`
    = the specific reply). Same fan-out (`get_bus().publish(session_id, {"event":
    "message.created", ...})`, now including `reply_to_message_id`/`thread_root_id` in the
    payload) and the same `_should_trigger_agent` gate as the main send path — a message
    thread is not a new trigger surface, it reuses G5's existing rule unchanged.
  - `GET /threads/{session_id}/messages/{message_id}/replies?since=` — thread replies,
    oldest-first, author-enriched via `attach_authors` (same helper as the main transcript).
- Existing `GET /threads/{session_id}/messages` (`get_thread_messages`) is extended to:
  1. Filter to top-level only (`thread_root_id IS NULL`) — thread replies are hidden from
     the main transcript, per G2.
  2. Attach a lightweight `thread_summary: {reply_count, recent_repliers: [author...]}` per
     message via a new batched store query (`get_thread_reply_summaries(session_id,
     root_message_ids)`), so the "N replies + avatars" indicator renders without N+1 calls.

### Store layer (`src/db/store.py`)
- `append_message(...)` gains optional `reply_to_message_id`, `thread_root_id` kwargs
  (default `None`), threaded straight into the INSERT — every existing caller
  (`agent_dispatch.py`'s `_backfill_assistant`, `_run_agent_turn_async`, `_persist_decline`,
  `_persist_quota_block`, and `messages.py:send_message`) is source-compatible unchanged
  unless it wants to opt in.
- `get_session_messages` / `get_messages_since` add `AND thread_root_id IS NULL`.
- New `get_thread_replies(db, session_id, root_message_id, since=None)` and
  `get_thread_reply_summaries(db, session_id, root_message_ids: list[int]) -> dict[int,
  {"reply_count": int, "recent_repliers": list[str]}]` (single grouped query, not N+1).

### Agent dispatch propagation (`src/api/agent_dispatch.py`)
- `schedule_agent_turn` gains optional `reply_to_message_id`/`thread_root_id` passthrough
  parameters. When the *triggering* human message carries a `thread_root_id` (i.e. the
  `@agent` mention happened inside an open message thread), the agent's own persisted
  reply (`_backfill_assistant`, `_run_agent_turn_async`) must be written with the **same**
  `thread_root_id` (and `reply_to_message_id` = the triggering message), so the agent's
  answer lands inside the thread, not the main transcript. This is the one behavioral change
  to the agent-dispatch path; the trigger gate itself (`_should_trigger_agent`) is unchanged
  — satisfies G5.

### Real-time delivery (G4)
No new transport. The same `get_bus().publish(session_id, {"event": "message.created", ...})`
call is reused for both inline replies (G1) and thread messages (G2) — the payload simply
carries the new `reply_to_message_id`/`thread_root_id` fields. Frontend subscribers already
receiving this session's stream decide client-side how to render:
- `thread_root_id` absent/`null` → append to the main transcript (rendering the quoted
  parent preview if `reply_to_message_id` is set).
- `thread_root_id` present → if that thread's `MessageRepliesPanel` is currently open,
  append to it; otherwise, bump the root message's reply-count indicator in place (no full
  refetch) and lazily resolve the new replier's avatar into `recent_repliers`.

### Frontend (`digital-factory-ui`)
- `src/components/agent-chat/message.tsx:Message` — add a "Reply" hover action; when a
  message carries `reply_to_message_id`, render a quoted/collapsed preview strip (author +
  truncated content) above the bubble, click-to-scroll/highlight the parent.
- New `ReplyIndicator` (small component, distinct from the pre-existing `ThreadPanel` in
  `task-review-view.tsx` and distinct from the pre-existing session-level `MessageThread`
  feed component) — renders "N replies" + stacked recent-repliers avatars on a root message,
  opens...
- New `MessageRepliesPanel` — the message-thread reply view (side panel or inline
  expansion), lists the thread's replies (`GET .../replies`), and posts new ones (`POST
  .../replies`) through the same `subscribeToThread`/`sendThreadMessage`-style client
  functions, added as `getMessageThreadReplies` / `postMessageThreadReply` in
  `src/services/hermes-agent/chat.ts`.
- `types.ts`: extend `HermesMessage` with optional `reply_to_message_id`, `thread_root_id`,
  `thread_summary?: {reply_count, recent_repliers}` — optional/absent on legacy messages,
  consistent with how `author` was added in v4/T6.

### Notifications (G6)
- The explicit-`@mention` path is unchanged and unaffected — a reply or thread message that
  `@mention`s someone notifies exactly as today (`notification-service`'s existing mention
  wiring, `persist_mentions` → `schedule_notification`).
- The "notify original author on reply even without `@mention`" behavior from G6 is an
  **open product question** (per the approved product spec) and is **not implemented in
  v1**. The design leaves the extension point explicit: `append_message`'s new
  `reply_to_message_id` argument is exactly the data `notification_client.py` would need to
  add a `reply` notification type later — no schema or plumbing rework would be required to
  add it once product confirms the requirement.

## Dependency Analysis
- **hermes-agent** (migration + `models.py` + `store.py` + `messages.py` +
  `message_threads.py` (new) + `agent_dispatch.py` propagation) must land first — it is the
  schema/API foundation; fully additive and backward-compatible (nullable columns, existing
  endpoints unchanged in shape aside from added optional fields).
- **digital-factory-ui** (message.tsx reply UI, `ReplyIndicator`, `MessageRepliesPanel`,
  `types.ts`, `chat.ts` client functions) depends on the hermes-agent API/schema above and
  ships second.
- No changes required in `workflow-backend`, `user-service`, `notification-service`, or
  `workflow-bff` for v1 — reply/thread data and delivery stay entirely within hermes-agent's
  existing session/message/SSE domain. `notification-service` is only a *future* extension
  point (G6), not a v1 dependency.

## Parallelization / Blocking Analysis
- Within hermes-agent: the migration (schema) blocks everything else. `store.py` changes and
  the new `message_threads.py` router can be built in parallel once the migration lands (they
  touch different files); `agent_dispatch.py` propagation depends on the `store.py` signature
  change (new kwargs) landing first.
- `digital-factory-ui` work is entirely blocked on the hermes-agent API being available
  (new endpoints + extended payload fields) but its three pieces (message.tsx reply action,
  `ReplyIndicator`, `MessageRepliesPanel`) can proceed in parallel with each other once the
  API contract (field names, endpoint shapes) is fixed — this design fixes that contract, so
  frontend and backend task breakdowns need not be strictly serialized once the contract
  above is agreed, only the *backend merge* need land before frontend PRs merge.
- No cross-repo blocking beyond hermes-agent → digital-factory-ui.
