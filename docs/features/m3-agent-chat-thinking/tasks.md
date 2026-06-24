# Tasks — m3-agent-chat-thinking (Stream the Agent's Thinking)

> Feature status (reference): `in_tdd` → task planning. Stage `tasks`: awaiting approval.
> **Machine-mutable state (status, depends_on, branch, pr, log) lives in `tasks/T<n>.yaml`** —
> this file is narrative only. Source of truth for state is the YAML.

Design basis: `technical-design.md` (§4 chosen design, §6 parallelization). 2 tasks across 2
repos: **hermes-agent** (×1 — emit the ephemeral `agent.reasoning` SSE event on the live bus
translator) and **digital-factory-ui** (×1 — render a live thinking area that collapses to a
session-only "Show thinking" toggle). `workflow-bff` and `workflow-backend` need no change; there
is **no DB migration** (the "no DB" rule is honored by adding no persistence).

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | hermes-agent: emit ephemeral `agent.reasoning` SSE event (translator + callback wiring) | — |
| T2 | 2 | digital-factory-ui: live thinking area + session-only "Show thinking" collapse toggle | T1 |

---

## T1 — hermes-agent: emit ephemeral `agent.reasoning` SSE event

### Description
Wire the agent's **already-produced** reasoning trace to a new ephemeral SSE event so the UI can
stream it live (design §4.1). The vendored agent already exposes a streaming reasoning callback
(`vendor/.../chat_completion_helpers.py:1699-1707`) and the model already produces a *summarized*
thinking trace (Anthropic adaptive thinking, `anthropic_adapter.py:2418-2463`) — the gateway just
never wires `reasoning_callback`. This task adds the emission, on the **live** transport.

Key points (all in `hermes-agent`, single repo):
- Add `on_reasoning(delta)` to the base `HermesSSETranslator` (`src/streaming/sse.py`): accumulate
  reasoning **separately** from assistant content (do **not** append to content parts) and emit a
  new frame `event: agent.reasoning`, `data: {"object": "reasoning.delta", "content": "<text>"}`.
  Optionally emit a `{"object": "reasoning.done"}` frame at turn end.
- Override `on_reasoning` in `BusPublishingSSETranslator` (`src/streaming/bus_translator.py`):
  call `super().on_reasoning(...)` then `self._bus_publish("agent.reasoning", {"content": delta})`.
  Because the live turn dispatch already uses this translator (`agent_dispatch.py:516`), the event
  fans out to **all** members over `GET /threads/{id}/stream` — `stream.py:130-136` relays any bus
  event by name, so **no route change** is needed.
- Wire `reasoning_callback = _make_delta_callback(translator.on_reasoning)` at the `AIAgent(...)`
  instantiation in `src/api/agent_dispatch.py` (the site that today sets `stream_delta_callback`
  but no `reasoning_callback`). Bind the same callback at the legacy `/chat` site
  (`src/api/routers/chat.py:116`, base translator) so the non-default fallback streams thinking too.
- **No new persistence**: the `on_reasoning` path must NOT call `append_message(reasoning=…)`. The
  existing end-of-turn reasoning persistence (`messages.reasoning`, `sessions.reasoning_tokens`)
  is left exactly as-is and is never the source of anything the chat UI renders.
- **No behavior change** (NG2): the callback is observational; model params and the agent's posted
  output are unchanged. Multi-step/interleaved turns may emit reasoning in several bursts —
  `on_reasoning` simply keeps emitting.

Freezes the `agent.reasoning` event contract (name + `{object, content}` shape) that T2 consumes.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Add `HermesSSETranslator.on_reasoning(delta)` emitting `event: agent.reasoning` frames; accumulate reasoning separately from assistant content.
- [ ] Override `BusPublishingSSETranslator.on_reasoning` to also `_bus_publish("agent.reasoning", {"content": delta})`.
- [ ] Wire `reasoning_callback` at the `AIAgent(...)` site in `agent_dispatch.py` (bus path) and at `routers/chat.py:116` (legacy fallback).
- [ ] Assert the streaming-reasoning path performs no `append_message(reasoning=…)` write (no new persistence).
- [ ] Unit test: `on_reasoning` frame shape; reasoning kept separate from content frames; a no-reasoning turn emits no reasoning frames (OQ1).
- [ ] Test: `BusPublishingSSETranslator` publishes `agent.reasoning` to the bus; a `/threads/{id}/stream` subscriber receives it.
- [ ] Parity test: assistant final content stream is byte-identical with/without the reasoning callback wired (NG2/NG6).
- [ ] Run full `pytest` + `make lint` (ruff) clean before PR.

---

## T2 — digital-factory-ui: live thinking area + session-only "Show thinking" toggle

### Description
Render the streamed thinking (design §4.2): a live thinking area while the turn runs, collapsing
into a **session-only** "Show thinking" toggle on the final answer when the turn ends. Thinking is
ephemeral — held only in React state, never persisted, never re-read from history, so it is gone
on refresh (G3/G4/NG1). All in `digital-factory-ui`, single repo.

Key points:
- Add `thinking?: string` to `HermesMessage` (`src/components/agent-chat/types.ts`) — mirrors the
  existing ephemeral `ctaActive` pattern; never in the history payload.
- Add an `agent.reasoning` case to **both** parse paths: `parseThreadEvents` (live thread/stream
  fan-out — primary) and `parseHermesEvents` (legacy `/chat` fallback) in
  `src/services/hermes-agent/chat.ts`; extend the relevant event union(s) with
  `{ type: "agent.reasoning"; messageId?: string; content: string }`.
- Accumulate reasoning deltas onto the streaming assistant message's `thinking` in the panel
  handlers (`handleThreadEvent` / `handleSubmit`, `agent-chat-panel.tsx`), reusing the existing
  RAF delta buffer (`deltaPendingRef`) for smooth rendering (OQ4).
- New `ThinkingDisclosure` component: while streaming + `thinking` non-empty, show an expanded live
  area (replacing the `Loader` once the first delta arrives; the `Loader` still covers the
  pre-first-delta gap — OQ1/G2). On turn `done`, collapse to a `▶ Show thinking` toggle attached to
  the final answer, expandable for the life of the view. Reuse the `ToolCallGroup` `useState` +
  `ChevronRight` collapse idiom (`message-thread.tsx:123-177`) — there is no Accordion primitive.
- Render `ThinkingDisclosure` in **both** `MessageThread` and `channel-message-list` (after the
  message content, before tool calls) so behavior is identical on every surface (G5).
- Ensure `thinking` is never included in the `/sessions/{id}/messages` history fetch → after a
  reload only the persisted answer renders (G4/NG1).

### Required skills
- typescript-best-practices
- frontend-engineer
- heroui-react

### Subtasks
- [ ] Add `thinking?: string` to `HermesMessage` (`types.ts`); confirm it is never read from history.
- [ ] Extend event union(s) and add an `agent.reasoning` case to `parseThreadEvents` and `parseHermesEvents` (`chat.ts`).
- [ ] Accumulate reasoning deltas onto the streaming assistant message in `handleThreadEvent` / `handleSubmit`, reusing the RAF delta buffer.
- [ ] Build `ThinkingDisclosure`: live expanded area while streaming; collapse to "Show thinking" toggle on `done` (copy the `ToolCallGroup` collapse idiom).
- [ ] Render `ThinkingDisclosure` in `MessageThread` and `channel-message-list` (after content, before tool calls).
- [ ] Keep the `Loader` for the pre-first-delta gap; swap to the thinking area on first reasoning delta.
- [ ] Vitest: `agent.reasoning` parsed on both paths; live area accumulates across a multi-step turn; collapses on `done`; expand/collapse works.
- [ ] Vitest: simulated history re-fetch yields no `thinking` → after reload only the answer renders (G4/NG1).
- [ ] Run `pnpm lint` + `pnpm type-check` + `pnpm test` clean before PR.
