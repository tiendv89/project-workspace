# Product Specification

## Feature
- Feature ID: `m3-stop-agent-chat`
- Title: Stop Agent Chat — Interrupt a Running Agent Turn

## Background

The M3 agent-chat line introduced streaming chat with the Hermes agent: the agent's response
arrives token-by-token in the UI in real time (v1), with session history and context tools (v2),
conversational document authoring (v3), and multi-member threads with triggered-only dispatch (v4).

In every iteration, once the agent starts generating a response there is **no way to stop it.**
The token stream runs until the agent's turn completes — even if the user has already read enough,
typed a correction, or wants to redirect with a different prompt. This is a fundamental usability gap
that affects all versions of the chat surface.

## Problem

### Users cannot interrupt an in-progress agent turn

Once the agent begins generating, the user is locked out of directing it until the full response
lands. If the agent takes a wrong turn early — misunderstands the question, starts writing the
wrong document section, begins an approach the user wants to change — the user must wait for the
entire response to finish before they can correct it. There is no escape hatch.

### Long agent turns waste time and tokens

Some agent turns involve multi-step reasoning, document drafting, or tool calls that take
significant time. If the user realizes mid-stream that the generation is not what they wanted,
they currently have no way to stop — they must wait for the response to finish, then send a
follow-up asking the agent to start over. This wastes the user's time and burns tokens on output
that will be discarded.

### The UI provides no signal that stopping is possible

The current chat UI does not communicate that stopping is an option. Users who intuitively look
for a "Stop" button — behavior trained by every other AI chat interface — find nothing, which
undermines trust in the surface. The absence of a stop affordance makes the interface feel less
in-control than users expect.

### Stopping a channel @agent trigger has no mechanism

With v4's triggered-dispatch model, a user who sends `@agent` and immediately wants to cancel
(misclick, change of mind) cannot do so. The turn fires and runs to completion. This is especially
visible because the triggered dispatch is deliberate, and an accidental trigger with no way out
is disruptive.

## Goals

- **G1 — Stop button during active generation.** While the agent is generating a response (token
  stream in progress), the message input area displays a **Stop** button (replacing or augmenting
  the Send button). Clicking it immediately cancels the in-progress agent turn.
- **G2 — Immediate visual feedback.** The token stream halts within one render cycle of the user
  clicking Stop. The partially generated response remains visible in the thread, clearly marked
  as stopped (e.g. a trailing indicator such as "— stopped by user").
- **G3 — Input re-enabled instantly.** As soon as the agent turn is stopped, the message composer
  is unlocked and the user can type and send their next message immediately.
- **G4 — Clean server-side cancellation.** The stop signal propagates to the backend and to the
  Hermes agent process — the agent turn is cancelled server-side, not just visually suppressed
  on the client. Token generation halts at the server; no further tokens are streamed or billed
  after the stop.
- **G5 — Stopped turn preserved in thread history.** The partial response from the stopped turn
  is persisted in the conversation history, marked as `stopped`, so the record is complete and
  the user can refer back to what was generated up to that point.
- **G6 — Works across all chat surfaces.** The stop capability applies in feature-thread sessions,
  workspace-level team threads, and workspace channels (wherever the triggered `@agent` can run).
## Non-goals

- **NG1 — No stopping of orchestrator-managed task execution.** Stopping tasks that run via the
  agent-runtime orchestrator (implementation tasks, reviewer agents) is a separate surface and
  out of scope. This feature is chat-turn cancellation only.
- **NG2 — No message editing or deletion of the stopped partial response.** The stopped partial
  response is immutable in the history (same policy as all messages — v4 NG6).
- **NG3 — No "undo" of state already mutated by the agent.** If an agent turn began a lifecycle
  action (e.g. opened a PR, committed a document) before being stopped, those changes are not
  rolled back. Stop halts generation; it does not undo tool calls already executed.
- **NG4 — No queued stop / delayed cancellation.** The stop is immediate or not at all. There is
  no "stop after the current sentence" or deferred cancellation.
- **NG5 — No stop for human-to-human messages.** Only agent-generation turns can be stopped.
  Sent human messages are immutable.

## User Flows

### Stopping a mid-stream response

1. The user sends a message and the agent begins generating. The token stream appears in the
   thread; the Send button is replaced by a **Stop** button.
2. The user reads the opening of the response, sees it's heading in the wrong direction, and
   clicks **Stop** (or presses `Escape`).
3. The token stream stops immediately. The partial response stays in the thread with a stopped
   indicator. The composer unlocks.
4. The user types a corrected prompt and sends it; the agent starts a new turn.

### Cancelling an accidental @agent trigger

1. In a team thread, the user accidentally selects `@agent` and sends before they intended to.
2. The agent turn starts. The user immediately clicks **Stop**.
3. The turn is cancelled — no further output, composer re-enabled. The user can proceed without
   waiting for an unwanted, potentially long response.

### Stopping a long document-drafting turn

1. The user asks `@agent` to draft a technical design. The agent begins a long streaming response.
2. Partway through, the user decides they want to give the agent more context first. They click
   **Stop**.
3. The agent halts. The partial draft (which may be useful as a starting skeleton) remains in
   the thread, marked stopped. The user sends a follow-up with additional context and triggers
   a new turn.

## Acceptance Criteria

- While the agent is generating, a **Stop** button (or equivalent control) is visible and
  interactive in the chat UI.
- Clicking Stop halts the visible token stream within one render cycle and persists the partial
  response marked as stopped.
- The message composer is immediately re-enabled after stop; the user can send the next message
  without any additional action.
- The server-side agent turn is cancelled: token generation stops at the backend; no further
  content is produced or streamed after the stop signal is acknowledged.
- The stopped partial message is saved in session history and readable on reload.
- Stop works in all three chat containers: feature-thread sessions, workspace-level team threads,
  and workspace channels.
- No state mutated by the agent *before* the stop is rolled back; only generation is halted.
- Lint, type-check, and the full test suites of all touched repos pass before any PR.

## Scope

### In scope

**UI (digital-factory-ui)**
- Stop button rendered in the message input area while an agent turn is active; hidden / replaced
  by Send when no turn is running.
- Visual "stopped" indicator appended to the partial message bubble.
- Composer unlocks immediately on stop.

**Backend (workflow-bff / workflow-backend)**
- A `STOP` signal endpoint or message type on the existing real-time transport (SSE or equivalent)
  that the UI sends when the user clicks Stop.
- Server-side handling: propagate the cancellation to the Hermes agent turn and close the
  streaming response cleanly.
- Persist the partial message with a `stopped` status in the session/message store.

**Hermes agent (hermes-agent)**
- Handle an abort signal mid-turn: stop producing tokens, flush any buffered output, and exit
  the turn cleanly without error.
- Do not roll back tool calls already executed before the stop signal.

### Out of scope

- Stopping orchestrator task agents (implementation, reviewer).
- Undo of agent-executed tool calls or document commits.
- Message edit/delete of the stopped partial response.

## Open Questions

- **OQ1 — Stop signal transport.** Should Stop be sent as an HTTP `DELETE /turns/:id` request,
  a control message on the SSE connection, or a WebSocket message? Resolution deferred to
  technical design.
- **OQ2 — Partial message persistence threshold.** Should a stopped message with zero tokens
  generated (e.g. stopped before any output) still be persisted? Likely no — but the edge case
  needs a clear rule.
- **OQ3 — Concurrent stop from multiple thread members.** In a multi-member thread (v4), any
  member can see the agent-is-working indicator. Should any member be able to stop the turn, or
  only the member who triggered it? Initial inclination: the triggering member only, to preserve
  clear ownership.

## References

- v1 chat spec: `docs/features/m3-agent-chat/product-spec.md`
- v2 chat spec: `docs/features/m3-agent-chat-v2/product-spec.md`
- v3 chat spec: `docs/features/m3-agent-chat-v3/product-spec.md`
- v4 chat spec: `docs/features/m3-agent-chat-v4/product-spec.md` — real-time transport,
  triggered-dispatch model, multi-member threads (the surface this feature improves)
- Touched repos: `digital-factory-ui` (Stop button UI, Escape binding, stopped-message rendering),
  `workflow-bff` / `workflow-backend` (stop signal routing, partial message persistence),
  `hermes-agent` (abort handling)
