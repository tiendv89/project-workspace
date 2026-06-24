# Product Specification

## Feature
- Feature ID: `m3-agent-chat-thinking`
- Title: Agent Chat — Stream the Agent's Thinking

## Background

The M3 agent-chat line lets humans and the resident Hermes agent co-author a feature's
artifacts through conversation. As of **v4 ("The Thread")** the chat is a multi-member,
real-time thread: messages and agent posts stream live to every member over an SSE transport,
and while the agent runs a turn the thread shows a lightweight **"agent is working"** status
indicator.

That indicator is **opaque**. It tells members *that* the agent is busy, but not *what* it is
doing. On a long turn — reading workspace context, loading skills, drafting a spec — the thread
shows nothing but a spinner for an extended period. To the user this reads as **stuck**: no
visible progress, no sense of whether the agent is making headway or hung.

Modern agent UIs solve this by **streaming the agent's thinking** — the model's reasoning trace
— so the user can watch the agent work in real time. This feature brings that to the chat
thread: while the agent runs, its thinking streams live into the thread; when the turn finishes,
the thinking collapses behind a toggle next to the final answer. The thinking is **ephemeral** —
it is never written to the database, so it does not survive a refresh or appear in history.

## Problem

### A running agent looks stuck
While the Hermes agent processes a turn, the only feedback is the binary "agent is working"
indicator from v4. A turn that takes many seconds (or longer) shows no progress, no intermediate
state, and no sign the agent is actually advancing. Users cannot tell a slow-but-healthy turn
from a hung one, so a normal long turn *feels* broken — eroding trust in the agent and tempting
users to refresh, re-send, or abandon the thread.

### The agent's reasoning is invisible
The agent produces a rich internal reasoning trace as it works, but none of it reaches the user.
The user sees only the final post, with no window into *how* the agent got there — what it
considered, what context it pulled, how it decided. That makes the agent feel like a black box
and gives the user nothing to react to until the entire turn completes.

### There is no lightweight, throwaway way to show progress
The thread's message model is built for persisted, attributed posts. There is no notion of an
**ephemeral, in-flight** stream that shows progress during a turn and then steps aside — without
becoming a permanent part of the transcript or a row in the database.

## Goals

- **G1 — Stream thinking live.** While the Hermes agent runs a turn, its thinking/reasoning
  trace streams token-by-token into the thread in real time, over the same v4 SSE transport that
  carries messages and the "agent is working" status. The user watches the agent work instead of
  staring at a spinner.
- **G2 — Replace the opaque spinner with visible progress.** The streamed thinking *is* the
  working indicator: when a turn starts, a thinking area appears attributed to the agent and
  fills in live; the user always has concrete, moving evidence the agent is advancing.
- **G3 — Collapse to a toggle when the turn ends (session-only).** When the agent posts its
  final answer, the streamed thinking collapses into a **"Show thinking"** toggle shown next to
  that answer for the rest of the current view. The thinking is **not persisted** — it is gone
  on refresh, reload, or when the thread is reopened later. The toggle exists only as long as the
  live view that streamed it.
- **G4 — Ephemeral: never written to the database.** Thinking tokens are a live-only signal.
  They are never stored as messages or in any persisted thinking record. The persisted transcript
  contains exactly what it does today: the human messages and the agent's final posts —
  unchanged. (No new tables, no message rows for thinking.)
- **G5 — Works on every surface the agent runs on.** Thinking streams in feature threads,
  workspace-level threads, and channels — every context where an `@agent` turn is triggered
  (v4). The behavior is identical everywhere the agent works.
- **G6 — Clearly attributed and visually distinct from answers.** The thinking stream is clearly
  marked as the agent's thinking and is visually distinguished from the agent's actual posted
  answer, so no one mistakes in-flight reasoning for a committed message or a gating decision.
- **G7 — Multi-member: all members see the same live thinking.** Because thinking rides the v4
  real-time fan-out, every member of the thread sees the same thinking stream live during the
  turn (consistent with how all members already see the "agent is working" status). The
  collapse-to-toggle and non-persistence (G3/G4) apply per live view.

## Non-goals

- **NG1 — Not persisted, not in history.** Thinking is never saved to the database and never
  appears when a thread is reloaded, reopened, or viewed in history. Reconstructing past thinking
  is explicitly out of scope.
- **NG2 — No change to the agent's behavior, tools, or output.** This feature only *surfaces* a
  reasoning trace the agent already produces. It does not change what the agent decides, which
  skills/tools it loads, what it posts, or the v3 authoring / PR pipeline.
- **NG3 — No change to gating or approval.** Thinking is informational only. It confers no
  authority and is never a gating action; v4/v3 human-gated approval semantics are unchanged
  (G6 keeps thinking visually separate from posted answers precisely so it is never mistaken for
  one).
- **NG4 — No interaction with the thinking.** The thinking stream cannot be edited, replied to,
  reacted to, quoted, copied as a message, or `@mentioned`. It is a read-only progress view that
  appears and then collapses.
- **NG5 — No new transport.** This reuses v4's existing SSE per-thread subscription and fan-out.
  No new real-time channel, no polling, no WebSocket migration.
- **NG6 — No streaming of the final answer's tokens as "thinking."** The final posted answer
  continues to be delivered as it is today; "thinking" refers to the reasoning trace that
  precedes and accompanies the turn, not a re-labeling of the answer stream.
- **NG7 — No analytics, logging, or export of thinking.** Because it is ephemeral (G4), thinking
  is not captured for analytics, audit, debugging, or export anywhere in the product.
- **NG8 — No per-user or per-thread setting to disable thinking in v1.** Thinking-on is the
  behavior for all turns on all surfaces (G5). A toggle to suppress it is a possible follow-on,
  not part of this feature.

## User Flows

### Watching the agent think
1. A user `@mentions` the agent in a thread to trigger a turn (v4).
2. Instead of an opaque spinner, a thinking area appears attributed to the agent and begins
   filling in live — the user reads the agent's reasoning as it streams (G1, G2).
3. All other members of the thread see the same thinking stream live (G7).
4. When the agent finishes, it posts its final answer as a normal attributed message; the
   thinking collapses into a **"Show thinking"** toggle next to that answer (G3).
5. The user can expand the toggle to re-read the reasoning **for as long as this view stays
   open**. If they refresh or reopen the thread later, the thinking is gone and only the final
   answer remains (G3, G4, NG1).

### A long turn no longer looks stuck
1. The agent is triggered for a turn that takes a while (heavy context-gathering, a long draft).
2. The thinking streams continuously throughout, so the user sees steady, concrete progress and
   never faces a silent spinner — the turn reads as *working*, not *hung* (G2).

### Thinking in a channel or workspace thread
1. A member `@mentions` the `@agent` in a channel (or a workspace-level thread).
2. The thinking streams and then collapses exactly as in a feature thread — identical behavior on
   every surface (G5).

## Scope

### In scope

**Thinking stream emission (hermes-agent / backend)**
- Capture the Hermes agent's reasoning trace during a triggered turn and emit it as an
  **ephemeral, in-flight thinking signal** distinct from the final posted message.
- The thinking signal is *not* written to the message store or any persisted record (G4, NG1).

**Real-time delivery (backend / bff over the v4 SSE transport)**
- Carry thinking tokens (and a turn-start / turn-end framing for the thinking area) over the
  existing v4 per-thread SSE subscription, fanned out to **all current members** of the thread
  (G7), reusing the same channel that already delivers the "agent is working" status (NG5).
- Thinking events are transient: a member who connects mid-turn may join the stream in progress;
  there is no replay of thinking after the turn ends (consistent with G4 — nothing is stored to
  replay).

**Rendering (digital-factory-ui)**
- A live, clearly-attributed, visually-distinct **thinking area** that appears when a turn starts
  and fills in token-by-token (G1, G2, G6).
- On turn completion, collapse the thinking into a **"Show thinking"** toggle attached to the
  agent's final answer, expandable for the duration of the current view only (G3).
- No persistence on the client beyond the current live view; on reload the toggle is absent
  (G4, NG1).
- Identical rendering across feature threads, workspace threads, and channels (G5).

### Out of scope (tracked separately)
- Persisting, replaying, or showing historical thinking (NG1).
- A user/thread setting to disable thinking (NG8).
- Any analytics, audit, logging, or export of thinking (NG7).
- Changes to agent behavior, tools, the authoring/PR pipeline, or gating/approval (NG2, NG3).
- Streaming or re-labeling the final answer's own tokens (NG6).

## Skills and agent tools

This is a **transport-and-rendering** feature layered on v4. It does not add agent tools or
change the authoring/lifecycle mechanics.

**Reused, unchanged:**
- The v4 SSE per-thread subscription and member fan-out (the same channel that carries messages
  and the "agent is working" status).
- The v3/v4 message-posting path for the agent's final answer (unchanged — thinking is a
  separate, ephemeral signal alongside it).
- The triggered-dispatch path that decides when the agent runs (v4) — thinking streams during
  whatever turn that path already invokes.

**New for this feature:**
- An **ephemeral thinking signal**: emit the agent's reasoning trace during a turn without
  persisting it.
- A **thinking event type** on the existing SSE transport (turn-start framing, thinking tokens,
  turn-end framing), fanned out to all members.
- UI: a live thinking area that streams and then collapses to a session-only "Show thinking"
  toggle.

## Open Questions

- **OQ1 — Thinking-area framing.** When a turn produces little or no reasoning trace before the
  answer, should the thinking area still appear briefly, or only once the first thinking token
  arrives? (Leaning: show the working state immediately on turn-start, replace with thinking
  tokens as they arrive — preserves G2's "never a silent spinner.")
- **OQ2 — Mid-turn join.** For a member who opens the thread *after* a turn has already started,
  is joining the in-progress thinking stream (no back-fill of already-emitted tokens) acceptable,
  or should they see only the working state until the next token? (Leaning: join in progress; no
  back-fill, since nothing is stored — consistent with G4.)
- **OQ3 — Source of the trace.** Confirm the exact reasoning signal emitted by the model/agent
  runtime that should be surfaced as "thinking," and that capturing it has no effect on the
  agent's output (NG2). (Technical-design concern; flagged here so the design pins it down.)
- **OQ4 — Verbosity / rate.** Should thinking tokens be forwarded raw, or lightly throttled/
  batched for readability and transport cost, given they are discarded after the turn? (Leaning:
  light batching for smooth rendering; no semantic filtering.)

## Success Criteria

- When the agent is triggered, members see its thinking stream live in the thread in place of an
  opaque spinner; a long turn shows continuous progress and never reads as stuck.
- The thinking is clearly attributed to the agent and visually distinct from its posted answer;
  no member can mistake in-flight thinking for a committed message or a gating action.
- When the turn ends, the thinking collapses into a "Show thinking" toggle next to the final
  answer; expanding it re-shows the reasoning for the current view.
- After a refresh / reopen, the thinking is gone and only the human messages and the agent's
  final answer remain — confirming nothing was written to the database.
- The behavior is identical in feature threads, workspace threads, and channels.
- All members of a thread see the same thinking stream live during a turn.
- No change to agent behavior, posted output, the v3/v4 authoring & PR pipeline, or any
  gating/approval semantics.
- Lint, type-check, and the full test suites of the touched repos pass before any PR.

## Reference
- v4 spec (the multi-member, real-time thread + SSE transport and "agent is working" status this
  feature extends): `docs/features/m3-agent-chat-v4/product-spec.md`
- v3 spec (conversational authoring, PR-tracked commits, in-chat approval — unchanged here):
  `docs/features/m3-agent-chat-v3/product-spec.md`
- Roadmap milestone: `docs/roadmap-milestone.md` → **M3 — The Thread**.
- Likely touched repos (subject to technical design): `hermes-agent` (emit the ephemeral
  reasoning trace during a turn), `workflow-backend` / `workflow-bff` (carry thinking events over
  the existing v4 SSE fan-out without persisting them), and `digital-factory-ui` (live thinking
  area + collapse-to-toggle rendering).
