
# Tasks — chat-reply-and-thread

## Dependency diagram

```
T1 (migration + models)
  └─▶ T2 (store.py: append_message kwargs, transcript filter, thread queries)
        ├─▶ T3 (API: message_threads.py router + messages.py reply_to_message_id + thread_summary)
        │     └─▶ T5 (FE: types.ts + chat.ts client functions)
        │           ├─▶ T6 (FE: message.tsx reply action + quoted preview)
        │           ├─▶ T7 (FE: ReplyIndicator)
        │           └─▶ T8 (FE: MessageRepliesPanel)  [depends on T7 too — opens from indicator]
        └─▶ T4 (agent_dispatch.py: thread_root_id propagation to agent replies)
```

## Index

| ID | Title | Repo | Depends On | Actor |
|---|---|---|---|---|
| T1 | Migration + Message model: reply_to_message_id, thread_root_id | hermes-agent | | agent |
| T2 | Store layer: append_message kwargs, transcript filter, thread reply queries | hermes-agent | T1 | agent |
| T3 | API: message_threads router + reply-to-message support + thread_summary | hermes-agent | T2 | agent |
| T4 | Agent dispatch: propagate thread_root_id to agent-authored replies | hermes-agent | T2 | agent |
| T5 | FE: types.ts + chat.ts client functions for replies/threads | digital-factory-ui | T3 | agent |
| T6 | FE: inline reply action + quoted parent preview in Message | digital-factory-ui | T5 | agent |
| T7 | FE: ReplyIndicator (reply count + recent repliers) | digital-factory-ui | T5 | agent |
| T8 | FE: MessageRepliesPanel (message-thread view) | digital-factory-ui | T5, T7 | agent |

## T1 — Migration + Message model: reply_to_message_id, thread_root_id

### Description
Add a new Alembic/SQL migration and update `src/db/models.py:Message` with two new
nullable columns: `reply_to_message_id` (BigInteger, FK `messages.id`) and
`thread_root_id` (BigInteger, FK `messages.id`). Add indexes
`idx_messages_thread_root (session_id, thread_root_id, created_at)` and
`idx_messages_reply_to (reply_to_message_id)`. Both columns must be nullable and default
`NULL` so existing rows and every existing code path are unaffected.

### Required skills
- python-best-practices

### Subtasks
- [ ] Write migration adding `reply_to_message_id` and `thread_root_id` columns + both indexes to `messages`
- [ ] Update `src/db/models.py:Message` with the two new `Column` definitions and `__table_args__` indexes
- [ ] Add/extend unit tests asserting the columns exist, are nullable, default `NULL`, and legacy rows are unaffected

## T2 — Store layer: append_message kwargs, transcript filter, thread reply queries

### Description
Extend `src/db/store.py`:
- `append_message(...)` gains optional `reply_to_message_id`, `thread_root_id` kwargs
  (default `None`), passed straight into the INSERT. All existing callers remain
  source-compatible.
- `get_session_messages` / `get_messages_since` add `AND thread_root_id IS NULL` so thread
  replies are excluded from the main transcript.
- New `get_thread_replies(db, session_id, root_message_id, since=None)` — oldest-first
  replies for a given thread root.
- New `get_thread_reply_summaries(db, session_id, root_message_ids: list[int]) -> dict[int,
  {"reply_count": int, "recent_repliers": list[str]}]` as a single grouped query (not N+1).

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `reply_to_message_id`/`thread_root_id` kwargs to `append_message`, threaded into the INSERT
- [ ] Add `thread_root_id IS NULL` filter to `get_session_messages` and `get_messages_since`
- [ ] Implement `get_thread_replies`
- [ ] Implement `get_thread_reply_summaries` as a single grouped/batched query
- [ ] Unit tests: append with/without new kwargs, transcript filter excludes thread replies, reply queries, summary batching correctness (no N+1)

## T3 — API: message_threads router + reply-to-message support + thread_summary

### Description
- Extend `SendMessageRequest` (existing `POST /threads/{session_id}/messages`) with optional
  `reply_to_message_id: Optional[str] = None`, passed through to `append_message`.
- New `src/api/routers/message_threads.py`:
  - `POST /threads/{session_id}/messages/{message_id}/replies` — validates the target
    message's `thread_root_id IS NULL` (else 400 `nested_thread_not_supported`), persists via
    `append_message(thread_root_id=message_id, reply_to_message_id=...)`, resolves/persists
    `@mention`s (reuse existing mention pipeline), fans out via `get_bus().publish(session_id,
    {"event": "message.created", ...})` including the new fields, and applies the existing
    `_should_trigger_agent` gate + `schedule_agent_turn` unchanged.
  - `GET /threads/{session_id}/messages/{message_id}/replies?since=` — returns thread replies,
    oldest-first, author-enriched via `attach_authors`.
- Extend existing `GET /threads/{session_id}/messages` (`get_thread_messages`) to filter to
  top-level only and attach `thread_summary` per message using `get_thread_reply_summaries`.
- Register the new router in the app.

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `reply_to_message_id` to `SendMessageRequest` and thread through to `append_message`
- [ ] Create `message_threads.py` with POST/GET replies endpoints, validation, mention persistence, SSE fan-out, agent-dispatch gate reuse
- [ ] Extend `get_thread_messages` with top-level filter + `thread_summary` attachment
- [ ] Register new router
- [ ] Integration tests: post inline reply, post/get thread replies, nested-thread rejection (400), thread_summary shape and accuracy, SSE payload includes new fields, mention/notification path unaffected

## T4 — Agent dispatch: propagate thread_root_id to agent-authored replies

### Description
Extend `src/api/agent_dispatch.py:schedule_agent_turn` with optional
`reply_to_message_id`/`thread_root_id` passthrough parameters. When the triggering human
message carries a `thread_root_id` (agent was `@agent`-triggered inside an open message
thread), the agent's own persisted reply (`_backfill_assistant`, `_run_agent_turn_async`)
must be written with the same `thread_root_id` (and `reply_to_message_id` set to the
triggering message), so the agent's answer lands inside the thread rather than the main
transcript. The trigger gate (`_should_trigger_agent`) itself is unchanged.

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `reply_to_message_id`/`thread_root_id` passthrough params to `schedule_agent_turn`
- [ ] Propagate to `_backfill_assistant` and `_run_agent_turn_async` persistence calls
- [ ] Verify `_persist_decline` / `_persist_quota_block` also propagate thread context when triggered from within a thread
- [ ] Unit tests: agent reply inside a thread lands with matching `thread_root_id`; agent reply outside a thread is unaffected (both fields `NULL`); trigger gate behavior unchanged

## T5 — FE: types.ts + chat.ts client functions for replies/threads

### Description
Extend `HermesMessage` (`types.ts`) with optional `reply_to_message_id`, `thread_root_id`,
`thread_summary?: {reply_count, recent_repliers}` — optional/absent on legacy messages.
Add client functions in `src/services/hermes-agent/chat.ts`: `getMessageThreadReplies`,
`postMessageThreadReply`, and extend the existing send-message client function to accept an
optional `reply_to_message_id`.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Extend `HermesMessage` type with the three new optional fields
- [ ] Add `getMessageThreadReplies(sessionId, messageId, since?)` client function
- [ ] Add `postMessageThreadReply(sessionId, messageId, content, model?)` client function
- [ ] Extend existing send-message client function to accept optional `reply_to_message_id`
- [ ] Unit tests: type shape (legacy vs. full), client function URL/body construction and error handling

## T6 — FE: inline reply action + quoted parent preview in Message

### Description
In `src/components/agent-chat/message.tsx:Message`/`MessageContent`, add a "Reply" hover
action that opens the composer pre-targeted at `reply_to_message_id`. When a message carries
`reply_to_message_id`, render a quoted/collapsed preview strip (author + truncated content)
above the bubble; clicking it scrolls to and highlights the parent message.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add "Reply" hover action to `Message`/`MessageContent`
- [ ] Render quoted parent preview strip when `reply_to_message_id` is set
- [ ] Implement click-to-scroll/highlight of the parent message
- [ ] Component tests: reply action visibility, preview rendering with/without parent field, scroll/highlight behavior

## T7 — FE: ReplyIndicator (reply count + recent repliers)

### Description
New `ReplyIndicator` component (distinct from the pre-existing `ThreadPanel` in
`task-review-view.tsx` and the session-level `MessageThread` feed component), rendering "N
replies" plus stacked recent-repliers avatars on a root message using `thread_summary` from
the transcript payload. Live-updates in place when a new thread reply arrives via SSE
without a full refetch.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Build `ReplyIndicator` rendering reply count + recent repliers' avatars from `thread_summary`
- [ ] Wire SSE `message.created` events (with `thread_root_id` set) to bump the indicator in place
- [ ] Component tests: zero-reply (hidden), N-reply rendering, live-update on new SSE thread message

## T8 — FE: MessageRepliesPanel (message-thread view)

### Description
New `MessageRepliesPanel` component — the message-thread reply view (side panel or inline
expansion) opened via `ReplyIndicator` or the root message's "Reply in thread" action. Lists
a thread's replies (`getMessageThreadReplies`) and posts new ones
(`postMessageThreadReply`), subscribing to the parent session's existing SSE stream to
append live thread messages when the panel is open.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Build `MessageRepliesPanel` — fetch and render thread replies oldest-first, author-attributed
- [ ] Wire posting new replies via `postMessageThreadReply`
- [ ] Wire live SSE append while panel is open (filter by `thread_root_id` match)
- [ ] Wire panel open from `ReplyIndicator` and from the root message's "Reply in thread" action
- [ ] Component tests: fetch/render, post new reply, live SSE append, open/close from indicator and root action
