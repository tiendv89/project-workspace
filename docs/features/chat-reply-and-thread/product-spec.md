
# Product Specification

## Feature
- Feature ID: `chat-reply-and-thread`
- Title: Message Replies and Threads in Team Chat

## Problem
Team chat (delivered in `m3-agent-chat-v4`, hermes-agent + digital-factory-ui) already
supports multi-member sessions ("threads" at the session/container level), `@mention`,
real-time SSE delivery, and per-message author attribution
(`hermes-agent/src/db/models.py:Session`/message tables, `digital-factory-ui`
`message.tsx` / `MessageThread`). What it does **not** support is **message-level
reply structure**:

- **No reply-to-a-message.** Every message is posted flat, appended to the session's
  linear transcript (`hermes-agent/src/db/store.py:append_message`). A user cannot reply
  directly to a specific prior message — theirs or another member's. In a busy session
  with several participants and the agent, a new message has no way to indicate *which*
  message it is answering, so context is lost as soon as two conversations interleave.
- **No way to branch a focused sub-conversation off one message.** Users cannot start a
  **thread** rooted at a specific message to work out a side-discussion (e.g. a
  clarifying back-and-forth about one point) without it interleaving with, and cluttering,
  the main transcript that everyone else is reading.
- **No visual grouping of replies.** Because there is no parent/child relationship
  between messages, the UI cannot show "N replies" on a message, cannot collapse a
  reply chain, and cannot let a user open just that chain to read or reply within it.

### Naming note (avoid collision with existing "thread" terminology)
`m3-agent-chat-v4` already calls the **session container** a "thread" (a membership-scoped
conversation with `@mention` and a triggered agent). This feature introduces a **second,
narrower** concept: a **message thread** — a reply chain rooted at one message, nested
*inside* an existing session/thread. Everywhere in this document, "session" or "parent
thread" refers to the existing container; "message thread" (or just "thread" when the
message-level meaning is unambiguous from context) refers to the new reply-chain concept
introduced here. The UI and API must use an unambiguous label (e.g. "Thread" panel opened
from a message's "Reply in thread" action) so end users are not confused by the two levels.

## Goals
- **G1 — Reply to a specific message.** Any member of a session (human or the agent, when
  triggered) can reply directly to an existing message. The reply is visibly linked to the
  message it replies to (e.g. a quoted/collapsed preview of the parent message shown above
  the reply) and to its author, so it's clear who is replying to whom.
- **G2 — Create a message thread.** Any member can open a **message thread** rooted at any
  existing message ("Reply in thread"). Replies posted inside that thread are scoped to the
  thread — they do not append to the main session transcript — but the parent session still
  shows a lightweight indicator on the root message: reply count, and the most recent
  repliers' avatars.
- **G3 — Thread visibility follows session membership.** A message thread is visible to,
  and repliable by, the same member set as its parent session — no separate membership
  model. Opening/reading/replying in a thread does not require an extra invite step.
- **G4 — Real-time delivery for replies and thread messages.** Both a direct reply in the
  main transcript and a message posted inside a message thread are delivered live over the
  existing SSE transport to every session member who has that session open, consistent with
  the delivery guarantee `m3-agent-chat-v4` established for top-level messages.
- **G5 — The agent can be replied to and can reply.** A user can reply directly to one of
  the agent's messages, or to a human's message inside a thread that also includes the
  agent. The agent only posts back when explicitly triggered via `@agent`, per the
  triggered-not-self-dispatching guardrail already established for the parent session —
  replies and threads do not change that gate.
- **G6 — Notifications respect the existing mention/DM/channel model.** A reply that
  `@mention`s a member notifies them via the existing `notification-service` mention path.
  Being replied to (without an explicit `@mention`) should also surface a lightweight
  notification to the parent message's author, so they know their message got a reply even
  if they weren't @mentioned — this needs explicit product confirmation (see Open Questions).

## Non-goals
- Redesigning the existing session/container-level "thread" concept from `m3-agent-chat-v4`
  (membership, `@mention`, channels) — this feature only adds message-level reply structure
  inside that existing container.
- Cross-session or cross-workspace replies (a reply/thread is always scoped to the single
  parent session it lives in).
- Nested threads (a "thread on a thread") — a message thread is a single flat level rooted
  at one top-level (or already-in-thread) message; this spec does not require unbounded
  reply depth.
- Editing or deleting the reply/thread relationship after posting (e.g. moving a reply to a
  different parent) — out of scope for v1.
- Rich thread-level features beyond membership parity — e.g. per-thread notification
  mute/follow settings — deferred to a later iteration unless called out as a stretch goal
  by the human reviewer.

## Open Questions
- Should being replied-to (without `@mention`) generate a notification to the original
  author, or should reply notification rely solely on explicit `@mention`, matching the
  existing `notification-service` "mention-only" trigger model? (Affects G6 and the
  technical design's notification wiring.)
- Should a message thread be closable/collapsible permanently, or does it always remain
  reachable via "N replies" on the root message?
- Do channel-kind sessions (`sessions.kind='channel'` from `m3-agent-chat-v4`) get
  message-thread support in v1, or is this limited to feature/DM-style sessions initially?
