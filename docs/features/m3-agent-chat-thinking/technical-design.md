# Technical Design

## Feature
- Feature ID: `m3-agent-chat-thinking`
- Title: Agent Chat — Stream the Agent's Thinking

> **Current state verified against live code on 2026-06-24** — branch `main` of `hermes-agent`
> (HEAD `f89b4752`) and `digital-factory-ui` (HEAD `e7c013f`), both present locally as siblings
> under `/Users/pye/code/kitelabs/`. Findings below cite real paths + symbols. RAG/GitNexus MCP
> were not in this session, so the rag-context pre-flight degraded gracefully (no snippets
> injected). This design builds on the v3/v4 agent-chat line — the SSE translators, the merged-and-
> live v4 thread subscription (`/threads/{id}/stream`) + realtime bus, and the legacy `/chat`
> fallback.

---

## 1. Current State

### The agent already produces a reasoning trace — it is just never streamed
hermes-agent runs each chat turn through a bundled ("vendored") agent
(`run_conversation` → `vendor/hermes-agent/agent/conversation_loop.py`). The LLM call is an
OpenAI-compatible client; Anthropic models go through an adapter
(`vendor/hermes-agent/agent/anthropic_adapter.py`).

- **Thinking is enabled.** For Claude 4.6+ the adapter requests adaptive thinking
  (`anthropic_adapter.py:2418-2463`):
  ```python
  kwargs["thinking"] = {"type": "adaptive", "display": "summarized"}
  kwargs["output_config"] = {"effort": adaptive_effort}  # medium/high/max/xhigh
  ```
  Older models use manual thinking with a token budget; OpenAI/DeepSeek models surface
  `reasoning_content` / `<think>` deltas. **The model produces a (summarized) reasoning trace
  today.**
- **A streaming reasoning callback already exists** in the vendored agent:
  `stream_converse_with_callbacks(..., on_reasoning_delta=...)` →
  `agent._fire_reasoning_delta(text)` → `agent.reasoning_callback`
  (`vendor/.../chat_completion_helpers.py:1699-1707`). A non-streaming fallback also extracts
  reasoning post-response (`chat_completion_helpers.py:820-851`).
- **The gateway does not wire it.** The agent is instantiated with `stream_delta_callback`,
  `tool_start_callback`, and `tool_complete_callback` — but **no `reasoning_callback`**
  (`src/api/agent_dispatch.py:328-345`). So the reasoning trace is produced and (see below)
  persisted, but **never streamed to the UI**. *This single gap is the feature.*

### Reasoning is already persisted (relevant to the "no DB" constraint)
The agent's `append_message` is mirrored to Postgres via `GatewaySessionDB`
(`src/db/session_db_proxy.py:62-149`) → `pg_append_message` (`src/db/store.py:277-317`). The
`messages` table already carries `reasoning`, `reasoning_content`, `reasoning_details`,
`codex_reasoning_items` (`src/db/models.py:87-90`) and `sessions.reasoning_tokens`
(`models.py:43`). **End-of-turn reasoning is persisted today, independent of any UI streaming.**
This pre-dates this feature and is **not** what the product spec's "no DB" rule targets (see
§2 and §3.4).

### The SSE translator and the two transports
- **Base translator** `src/streaming/sse.py` (`HermesSSETranslator`) emits, on the per-turn
  `/chat` stream: OpenAI `chat.completion.chunk` (lead frame, content deltas via `on_delta`,
  finish frame), `hermes.tool.progress` (`on_tool_start`/`on_tool_complete`),
  `hermes.artifact.saved`, an error finish, and `[DONE]`. **There is no reasoning event.**
- **Bus translator** `src/streaming/bus_translator.py` (`BusPublishingSSETranslator`) extends the
  base and *also* publishes structured events to the in-process `SessionBus`
  (`src/realtime/bus.py`): `agent.delta`, `hermes.tool.progress`, `hermes.artifact.saved`,
  `agent.done`, and a documented-but-unimplemented `agent.working`.
- **v4 fan-out is fully merged and is the live path.** `bus.py` and `BusPublishingSSETranslator`
  exist, the v4 schema is migrated (`session_members`, `message_mentions`, `messages.author_id`,
  `sessions.kind` — `migrations/002_team_chat_v4.sql`), **and the thread routes are present and
  wired** (`src/api/router.py:12-17`): `GET /threads/{id}/stream` (`routers/stream.py:60`),
  `POST /threads/{id}/messages` (`routers/messages.py:102`), `POST /threads/{id}/typing`,
  `POST /threads/{id}/cancel`, plus `routers/{threads,channels,members}.py`.
- **The turn dispatch publishes to the bus.** `agent_dispatch.py:516` builds a
  `BusPublishingSSETranslator(session_id, model)` and publishes `agent.working` at turn start
  (`:520`) and a follow-turn translator at `:428`; the agent's deltas / tool progress / artifact
  frames are fanned out to the in-process `SessionBus`. `GET /threads/{id}/stream`
  (`routers/stream.py:104-136`) subscribes to that bus and relays every event — `message.created`,
  agent deltas, `hermes.tool.progress`, `hermes.artifact.saved`, `agent.working`, `typing`,
  `member.changed`, `channel.deleted` — to **all** members, with a `?since=` DB replay on
  (re)connect. **This — the bus fan-out over `/threads/{id}/stream` — is the live multi-member
  transport.**
- **The legacy `/chat` route still uses the base translator.** `routers/chat.py:116` constructs a
  plain `HermesSSETranslator` (single caller, no fan-out). It coexists as a fallback path; the
  primary surface uses the thread subscription (below).

### Frontend — the subscription transport is the active path
- `src/services/hermes-agent/chat.ts` has **both** `streamChatTurn` (legacy `POST /api/v1/chat`,
  `chat.ts:193-236`) and `subscribeToThread` (`GET /threads/{id}/stream`, `chat.ts:407-445`),
  each via `@microsoft/fetch-event-source`. The `AgentChatPanel` prop defaults
  `useSubscriptionTransport = false` (`agent-chat-panel.tsx:89`), **but the real call site —
  `feature-workbench.tsx:241` — passes it on**, so the feature chat runs on the **thread
  subscription / bus fan-out** path. Channels and workspace threads are inherently on the same
  thread/stream path. (The legacy per-turn `/chat` remains only as a non-default fallback.)
- Event parsing: `parseHermesEvents` (v3, `chat.ts:257-306`) → `HermesEvent` union
  (`chat.ts:29-36`); `parseThreadEvents` (v4, `chat.ts:447-512`) → `ThreadEvent` union
  (`chat.ts:308-321`, already includes `agent.working`, `typing`, `message.created`, …).
- Rendering: `HermesMessage` (`types.ts:10-27`) = `{id, role, content, toolCalls?, author?, …}`.
  `MessageThread` (`message-thread.tsx`) renders the message, then `ToolCallGroup`, then CTA row,
  with a `Loader` ("Agent is responding" — three bouncing dots, `loader.tsx`) shown while
  `status === "streaming"`. Channel view is `channel-message-list.tsx`.
- **No reasoning/thinking handling exists** in either parse path or any component. **No Accordion
  primitive** — collapsibles are hand-rolled with `useState` + a rotating `ChevronRight`
  (`ToolCallGroup`, `message-thread.tsx:123-177`).
- Message state is local React state in `AgentChatPanel` (`messages`, `agent-chat-panel.tsx:96`);
  history is re-fetched from `/api/v1/sessions/{id}/messages` (no thinking field). Nothing
  chat-related is persisted client-side beyond `lastModel`/`selectedWorkspaceId` in a Zustand
  store.

---

## 2. Problem Framing

### What must change
1. **Stream the reasoning trace.** Wire the existing reasoning callback to a **new ephemeral SSE
   event** so the agent's thinking reaches the UI live during a turn (G1, G2).
2. **Render it, then collapse it.** The FE must show a live thinking area while the turn runs and
   collapse it into a **session-only "Show thinking" toggle** next to the final answer when the
   turn ends (G3).
3. **Keep it ephemeral to the user.** Add **no new persistence** for the streamed deltas, and
   **never read thinking back from history** — so it is gone on refresh/reopen (G4, NG1).

### What must stay stable (verified, reused)
- **The model call and the agent's output.** We only attach an observational callback; the
  reasoning trace already exists and is already requested. No change to model params, tools, the
  v3 authoring/PR pipeline, or what the agent posts (NG2). The final answer streams exactly as
  today (NG6).
- **The BFF and workflow-backend.** Reasoning rides the existing SSE envelope; the BFF proxies
  `text/event-stream` verbatim and workflow-backend owns no chat data — **neither changes**
  (matches v4's finding).
- **Gating/approval.** Thinking is informational; v3/v4 human-gated approval is untouched (NG3).
- **The existing end-of-turn reasoning persistence** (`messages.reasoning`, …). This feature
  neither relies on it for display nor changes it (§3.4).

### Fixed assumptions
- The reasoning signal to surface is the **already-produced** trace: Anthropic adaptive thinking
  (`display: "summarized"` on 4.6+) via `on_reasoning_delta`, or `reasoning_content`/`<think>`
  deltas for other models. Because `display: "summarized"`, what streams is a **summary**, not
  raw chain-of-thought — appropriate to show users. **(Resolves product-spec OQ3.)**
- hermes runs single-instance per workspace (M2 model) — so the in-process bus is a valid fan-out
  substrate (same assumption v4 made), and it is **already** the live multi-member transport (§1).
- The live transport is the v4 thread subscription / bus fan-out (`/threads/{id}/stream`); the
  dispatch already uses `BusPublishingSSETranslator`. The legacy `/chat` base-translator path is a
  non-default fallback (§1).

---

## 3. Options Considered

### 3.1 Where to emit the thinking signal — **decisive**
**Option A — emit once at the SSE translator layer (chosen).** Add `on_reasoning(delta)` to the
**base** `HermesSSETranslator` (a new `agent.reasoning` event), and wire
`reasoning_callback = translator.on_reasoning` in `agent_dispatch.py`. Because
`BusPublishingSSETranslator` **extends** the base translator, overriding `on_reasoning` there to
*also* `_bus_publish("agent.reasoning", …)` means the **same single emission point** serves both
transports.
- Pros: **one `on_reasoning` implementation** serves both transports. The live path —
  `BusPublishingSSETranslator` (`agent_dispatch.py:516`) — publishes `agent.reasoning` to the bus,
  so it **fans out to all members over `/threads/{id}/stream` immediately** (G5/G7), with no
  external dependency. The same base method also lights up the legacy `/chat` fallback. Fully
  additive; the callback is observational (NG2).
- Cons: two wiring sites if the base `/chat` fallback must also stream thinking (the bus dispatch
  at `agent_dispatch.py:516` and the base `/chat` translator at `chat.py:116`) — both bind the
  same `on_reasoning`, so it is duplication of one line, not of logic.
- **Chosen.**

**Option B — emit only on the legacy `/chat` base translator.** Would reach only the non-default
fallback surface and never fan out to thread members/channels. **Rejected** — the primary surface
is the thread subscription.

**Option C — emit only inside `BusPublishingSSETranslator`.** Reaches the live thread/stream
surface (the one that matters) but skips the `/chat` fallback. Acceptable, but Option A's base-class
method covers both for one extra line — **preferred**.

### 3.2 Persisting the streamed thinking (the "no DB" rule)
**Option A — add no new persistence; never surface persisted reasoning in chat (chosen).** The
new `agent.reasoning` deltas are SSE-only — our code does **not** call `append_message(reasoning=…)`
for them. The FE holds thinking in transient state and **never** requests it from the message read
API, so it is gone on refresh (G4, NG1). The pre-existing end-of-turn `messages.reasoning`
persistence is left **exactly as-is** (it serves token accounting and pre-dates this feature) and
is simply **never read** into the chat transcript.
- Pros: honors "shown only when streaming, not saved" precisely; zero schema change; no risk to
  the agent's existing accounting.
- **Chosen.**

**Option B — also strip the existing reasoning persistence.** Out of scope and risky — it would
touch the agent's token-accounting path (`sessions.reasoning_tokens`) for no product benefit
(the user-facing ephemerality is already achieved by Option A). **Rejected.**

### 3.3 FE thinking-state location
**Option A — a transient `thinking?: string` on the in-memory `HermesMessage` (chosen).** Mirrors
how `ctaActive` is already an ephemeral, never-persisted message field. Cleared automatically on
reload because it lives in React state and is never in the history payload.
- Pros: minimal; no new store; consistent with existing patterns; ephemerality is free.
- **Chosen.** (B — a separate Zustand slice — rejected: over-modeled for view-local, throwaway
  state.)

### 3.4 Collapse UI primitive
**Option A — reuse the hand-rolled `useState` + `ChevronRight` disclosure pattern (chosen).**
There is no Accordion/Disclosure primitive in the repo; `ToolCallGroup` already establishes the
collapse idiom (`message-thread.tsx:123-177`). A new `ThinkingDisclosure` copies it.
- Pros: visually consistent with tool-call collapsing; no new dependency. **Chosen.**

---

## 4. Chosen Design

**Summary:** wire the agent's existing reasoning callback to a new **ephemeral `agent.reasoning`
SSE event** emitted once at the translator layer (so it rides both the live v3 `/chat` stream and
the v4 bus fan-out), and render it in `digital-factory-ui` as a **live thinking area that
collapses to a session-only "Show thinking" toggle**. No persistence is added; the FE never reads
thinking from history. `hermes-agent` and `digital-factory-ui` are the only repos touched — the
BFF and workflow-backend are untouched.

### 4.1 hermes-agent — emit the reasoning event [T1]
- **`HermesSSETranslator.on_reasoning(delta: str)`** (new, `src/streaming/sse.py`): accumulate
  reasoning **separately** from assistant content (do **not** append to the content parts) and
  emit a frame:
  ```
  event: agent.reasoning
  data: {"object": "reasoning.delta", "content": "<summarized thinking text>"}
  ```
  Optionally emit `{"object": "reasoning.done"}` at turn end for clean FE framing (the existing
  `finish`/`[DONE]` frames already bound the turn, so a dedicated done frame is a nicety, not a
  requirement).
- **`BusPublishingSSETranslator.on_reasoning`** (override, `src/streaming/bus_translator.py`):
  call `super().on_reasoning(...)` then `self._bus_publish("agent.reasoning", {"content": delta})`.
  Because the **live dispatch already uses this translator** (`agent_dispatch.py:516`), the event
  **fans out to all members over `/threads/{id}/stream` immediately** (G5/G7) — `stream.py`'s
  generic relay (`stream.py:130-136`) forwards any bus event by name, so it carries
  `agent.reasoning` with no route change.
- **Wire the callback**: in `src/api/agent_dispatch.py`, at the `AIAgent(...)` instantiation (the
  site that today sets `stream_delta_callback`/`tool_start_callback`/`tool_complete_callback` but
  **no** `reasoning_callback`), add `reasoning_callback = _make_delta_callback(translator.on_reasoning)`.
  This is the one line that turns the feature on for the live thread path. Bind the same callback
  at the legacy `/chat` site (`routers/chat.py:116`, base `HermesSSETranslator`) so the fallback
  surface streams thinking too.
- **Persistence guard:** the `on_reasoning` path must **not** call `append_message(reasoning=…)`.
  The existing end-of-turn reasoning extraction/persistence (`chat_completion_helpers.py:820-851`
  → `session_db_proxy.py`) is left unchanged and is **not** the source of anything the chat UI
  renders (§3.2).
- **Interleaved/multi-step turns:** Claude adaptive thinking may emit reasoning in several bursts
  across a multi-step turn (before/between tool calls). `on_reasoning` simply keeps emitting
  deltas; the FE accumulates them for the whole turn.

### 4.2 digital-factory-ui — render + collapse [T2]
- **Type:** add `thinking?: string` to `HermesMessage` (`types.ts`) and
  `| { type: "agent.reasoning"; messageId?: string; content: string }` to the relevant event
  unions.
- **Parse on both transports:** handle `event === "agent.reasoning"` in **both** `parseHermesEvents`
  (covers the legacy `/chat` fallback) and `parseThreadEvents` (covers the live thread/stream
  fan-out path). One event-name string, handled in both — so no behavioral divergence between
  transports.
- **Accumulate:** in the panel's event handler (`handleSubmit` for v3 / `handleThreadEvent` for
  v4), append reasoning deltas to the streaming assistant message's `thinking` (reuse the existing
  RAF delta-buffering used for content, `deltaPendingRef`, for smooth rendering — resolves
  product-spec OQ4). Target the streaming assistant id (or `event.messageId` when present).
- **Live area → toggle:** a new `ThinkingDisclosure` component:
  - While the turn streams and `thinking` is non-empty, render an **expanded, live** thinking area
    in the streaming assistant slot (replacing the opaque `Loader` once the first reasoning delta
    arrives — resolves product-spec OQ1; the `Loader` still covers the gap before the first delta
    so a turn never shows a silent spinner — G2).
  - On turn end (`done`/finish), **collapse** to a `▶ Show thinking` toggle attached to the final
    answer, expandable for the life of the current view (G3). Copy the `ToolCallGroup`
    `useState` + `ChevronRight` idiom (§3.4).
  - Rendered in **both** `MessageThread` and `channel-message-list` (after the message content,
    before tool calls) so behavior is identical on every surface that renders chat (G5).
- **Ephemerality:** `thinking` lives only in React state and is **never** included in the
  `/sessions/{id}/messages` history fetch — so reload/reopen shows only the persisted answer
  (G4, NG1). No client-side persistence (no localStorage/Zustand).

### 4.3 Surface coverage (G5/G7) — delivered now, no transport dependency
Because emission is at the translator layer (§4.1) and the **live dispatch already uses
`BusPublishingSSETranslator`** publishing to a bus that `GET /threads/{id}/stream` relays to all
members:
- **Feature threads, workspace threads, and channels** all run on the thread/stream path, so
  `agent.reasoning` fans out to **every member** of the thread live — G5 (all surfaces) and G7
  (all members see the same thinking) are satisfied **immediately**, with no new transport and no
  external dependency (product-spec NG5 honored — we add an event, not a transport).
- The **legacy `/chat` fallback** (non-default) also streams thinking via the base-translator
  binding (§4.1), so any surface still on that path is covered too.
- A late subscriber joining a turn in progress gets the in-flight `agent.reasoning` stream with
  **no back-fill** (the `?since=` replay covers persisted `message.created` only; thinking is
  never persisted) — consistent with ephemerality (G4). Resolves OQ2.

### 4.4 End-to-end flow
Agent turn starts → `Loader` shows immediately → first `on_reasoning` delta → `agent.reasoning`
frames stream → FE shows a live thinking area filling in → (optional tool calls / more reasoning
bursts accumulate) → assistant content deltas stream the answer → turn `done` → thinking collapses
to a session-only "Show thinking" toggle beside the answer. Refresh → only the answer remains.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| Vendored agent exposes a streaming reasoning callback (`on_reasoning_delta` → `reasoning_callback`) | Existing | ✅ `chat_completion_helpers.py:1699-1707` | No — just unwired |
| Model produces a reasoning trace (Anthropic adaptive `display:summarized`; `reasoning_content`/`<think>` for others) | Existing | ✅ `anthropic_adapter.py:2418-2463` | No — resolves OQ3 |
| Base SSE translator is extensible with a new event | Existing | ✅ `src/streaming/sse.py` | No — additive |
| Bus translator inherits base (so one emission point serves both) | Existing | ✅ `bus_translator.py` extends `HermesSSETranslator` | No |
| BFF forwards the extended SSE envelope unchanged | Existing | ✅ generic `text/event-stream` pass-through (v4 finding) | No — **no BFF change** |
| FE has both parse paths to extend (`parseHermesEvents` + `parseThreadEvents`) | Existing | ✅ `chat.ts:257-306`, `447-512` | No |
| FE feature chat runs on the thread subscription transport | Existing | ✅ `feature-workbench.tsx:241` passes `useSubscriptionTransport` | No |
| **v4 thread-stream fan-out routes** `GET /threads/{id}/stream`, `POST /threads/{id}/messages` | Existing | ✅ **merged** (`routers/{stream,messages}.py`, wired in `router.py:12-17`); dispatch uses `BusPublishingSSETranslator` (`agent_dispatch.py:516`) | No — **fan-out is live** |
| `stream.py` relays arbitrary bus events by name (so `agent.reasoning` needs no route change) | Existing | ✅ `routers/stream.py:130-136` | No |
| Existing end-of-turn reasoning persistence | Existing | ✅ `messages.reasoning`, `sessions.reasoning_tokens` | No — left untouched, never read into chat |

**No blocking dependencies.** The transport that delivers thinking to all members
(`/threads/{id}/stream` + the bus dispatch) is **merged and live** — so G5 (all surfaces) and G7
(all members) are deliverable within this feature, not gated on any other work. The only remaining
caveat is cosmetic: any surface still pinned to the non-default legacy `/chat` path is covered by
binding the same `on_reasoning` to that path's base translator (§4.1).

---

## 6. Parallelization / Blocking Analysis

Two tasks, one repo each. The `agent.reasoning` event contract (name + `{object/kind, content,
messageId?}` shape) is **frozen at design approval**, so the FE can scaffold against it
immediately; T2 depends on T1 only for end-to-end integration testing against the real stream.

```
No external dependencies — the multi-member transport (GET /threads/{id}/stream + bus dispatch via
BusPublishingSSETranslator) is already merged and live, so thinking fans out to all members on all
surfaces within this feature (G5/G7).

T1: hermes-agent — emit ephemeral `agent.reasoning` SSE event
                   (HermesSSETranslator.on_reasoning + wire reasoning_callback in agent_dispatch;
                    BusPublishingSSETranslator override; no new persistence)
  └── Can begin now — no blockers (additive; callback already exists, just unwired)
  │
  T2: digital-factory-ui — live thinking area + collapse-to-session-toggle
                           (thinking? field; handle agent.reasoning in both parse paths;
                            ThinkingDisclosure; never read from history)
        └── BLOCKED on T1 (needs the real `agent.reasoning` event to integration-test end to end;
            event contract is frozen at design approval so component scaffolding may overlap)

Waves:
  Wave 1: T1                      (hermes-agent emission — independent)
  Wave 2: T2                      (digital-factory-ui rendering — integrates against T1's event)
```

---

## 7. Repository Impact

| Repo (`workspace.yaml` id) | Task | Changes | Why |
|---|---|---|---|
| `hermes-agent` | T1 | `HermesSSETranslator.on_reasoning` + `agent.reasoning` event (`src/streaming/sse.py`); wire `reasoning_callback` (`src/api/agent_dispatch.py`); `BusPublishingSSETranslator.on_reasoning` override (`src/streaming/bus_translator.py`); **no new persistence** | stream the existing-but-unwired reasoning trace (G1/G2) on both transports |
| `digital-factory-ui` | T2 | `thinking?` on `HermesMessage` (`types.ts`); handle `agent.reasoning` in `parseHermesEvents` + `parseThreadEvents` and the panel handlers (`chat.ts`, `agent-chat-panel.tsx`); new `ThinkingDisclosure`; render in `MessageThread` + `channel-message-list`; never read from history | live thinking area + session-only collapse toggle (G2/G3/G4/G5) |
| `workflow-bff` | — | **none** (extended SSE envelope proxied as-is) | — |
| `workflow-backend` | — | **none** (owns no chat data) | — |
| `hermes-agent` DB schema | — | **none** (no migration; "no DB" honored by adding no persistence) | — |

---

## 8. Validation and Release Impact

### Testing
- **T1** (pytest; `tests/src/test_streaming.py`, `test_stream_chat.py`):
  - `on_reasoning` emits well-formed `agent.reasoning` frames; reasoning is accumulated
    **separately** from assistant content (content frames unchanged).
  - With `reasoning_callback` wired, a streamed turn with reasoning produces reasoning frames
    **before/around** content frames; a turn with **no** reasoning produces none (no empty
    frames) — resolves OQ1.
  - **No new `append_message(reasoning=…)` call** results from streaming deltas (assert the
    persistence path is not invoked by `on_reasoning`); existing end-of-turn reasoning persistence
    still occurs unchanged.
  - `BusPublishingSSETranslator` publishes `agent.reasoning` to the bus in addition to the SSE
    frame.
  - Output parity: the assistant's final content stream is byte-identical with/without the
    reasoning callback wired (NG2/NG6).
- **T2** (vitest; `src/__tests__/components/agent-chat/`):
  - `agent.reasoning` parsed in both `parseHermesEvents` and `parseThreadEvents`.
  - Live thinking area appears on first reasoning delta and accumulates across a multi-step turn;
    `Loader` covers the pre-first-delta gap.
  - On `done`, the area collapses to a `Show thinking` toggle bound to the final answer; expand/
    collapse works.
  - History re-fetch (`getSessionMessages`) yields messages **without** `thinking` → after a
    simulated reload only the answer renders (G4/NG1).
  - Renders identically in `MessageThread` and `channel-message-list`.
- Each repo's full suite + lint/type-check before its PR (CLAUDE.md pre-push): Python/ruff/pytest
  (hermes-agent, `make lint` + `pytest`), and `pnpm lint` + `pnpm type-check` + `pnpm test`
  (digital-factory-ui).

### Migration / Config
- **No DB migration. No new env. No new infra.** Purely additive event + UI. The SSE envelope
  gains one event type (`agent.reasoning`); it is not a breaking change (existing consumers ignore
  unknown events).

### Rollout & backward compatibility
- Additive and low-risk: an older FE simply ignores the new `agent.reasoning` event; an unchanged
  BFF proxies it. The agent's output and the persisted transcript are unchanged.
- Thinking ships on the live thread subscription / bus fan-out path, so it reaches **all members
  on all surfaces** (feature threads, workspace threads, channels) at once (§4.3) — no transport
  work and no follow-on required. The legacy `/chat` fallback is covered by the same `on_reasoning`
  binding.

## Design assets (no Figma)
The product spec contains **no Figma URLs**, so the Figma-link propagation rule does not trigger
and the frontend task (T2) requires no `### Figma` subsection. If designs are added later, add a
`## Figma` section here mapping each frame to T2, and a `### Figma` subsection to T2 before it is
marked `ready`.

## Resolved decisions (formerly product-spec open questions)
- **OQ1 — thinking-area framing → RESOLVED.** Show the existing `Loader` immediately on turn
  start; replace it with the live thinking area on the **first** reasoning delta; if a turn emits
  no reasoning, no thinking area appears (no empty frames). Never a silent spinner (G2).
- **OQ2 — mid-turn join → RESOLVED.** On the live thread/stream fan-out, a late subscriber joins
  the in-progress `agent.reasoning` stream with **no back-fill** — the `?since=` replay
  (`stream.py`) covers persisted `message.created` only; thinking is never persisted, so there is
  nothing to replay. Consistent with ephemerality (G4).
- **OQ3 — source of the trace → RESOLVED.** The already-produced reasoning trace: Anthropic
  adaptive thinking (`display:"summarized"` on Claude 4.6+) via `on_reasoning_delta`, or
  `reasoning_content`/`<think>` deltas for other models. The callback is **observational** — it
  does not change model params or output (NG2). Because the trace is **summarized**, what users
  see is a summary, not raw chain-of-thought.
- **OQ4 — verbosity / rate → RESOLVED.** Forward deltas with **light client-side batching** (reuse
  the existing RAF delta buffer) for smooth rendering; **no semantic filtering**. Server forwards
  the trace as the model emits it.

No standing dependencies: the multi-member transport (`/threads/{id}/stream` + the bus dispatch) is
already merged and live, so G5/G7 are delivered within this feature (§5).

## Reference
- Product spec: `docs/features/m3-agent-chat-thinking/product-spec.md`
- v4 design reused/extended (SSE translator, bus, transport, `agent.working`):
  `docs/features/m3-agent-chat-v4/technical-design.md`
- Live code verified 2026-06-24:
  - `hermes-agent` (`main`): `src/api/agent_dispatch.py` (callback wiring; bus translator at
    `:516`, `agent.working` publish at `:520`, follow-turn at `:428`), `src/streaming/sse.py`,
    `src/streaming/bus_translator.py`, `src/realtime/bus.py`,
    `src/api/router.py:12-17`, `src/api/routers/{stream,messages,threads,channels,members,chat}.py`
    (`stream.py:60,104-136`, `messages.py:102`, `chat.py:116`),
    `vendor/hermes-agent/agent/anthropic_adapter.py:2418-2463`,
    `vendor/hermes-agent/agent/chat_completion_helpers.py:820-851,1699-1707`,
    `src/db/{models.py,store.py,session_db_proxy.py}`, `migrations/002_team_chat_v4.sql`,
    `tests/src/{test_streaming.py,test_stream_chat.py}`
  - `digital-factory-ui` (`main`): `src/services/hermes-agent/chat.ts:29-36,257-321,407-512`,
    `src/components/agent-chat/{agent-chat-panel,message-thread,channel-message-list,message,
    types,loader}.tsx`, `tool-cards/*`, `src/__tests__/components/agent-chat/`
- Lifecycle + rules: management-repo "no direct push to main", feature-branch rules, the thesis
  guardrail, and the pre-push test/lint rule in `CLAUDE.md`.
