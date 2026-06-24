# Technical Design

## Feature
- Feature ID: `m3-stop-agent-chat`
- Title: Stop Agent Chat — Interrupt a Running Agent Turn

> **Architecture grounded in the verified v4 design** (`m3-agent-chat-v4/technical-design.md`,
> verified 2026-06-14). This feature layers directly on top of v4's in-process pub/sub transport
> and decoupled send service. It is intentionally scoped small: two tasks, two repos, no new
> infrastructure.

---

## 1. Current State

### hermes-agent — turn runner and active-run guard

The agent turn is managed in `src/api/routers/chat.py` (v3 path — `POST /api/v1/chat`) and, after
v4, in the decoupled send service that processes `POST /api/v1/threads/{id}/messages`.

The concurrency guard is an **in-process set**:
```python
_active_runs: set[str]   # keyed by session_id
```
A new turn request 409s if the session id is already in the set. The turn is dispatched to a
worker thread via `_run_agent_turn` (asyncio task on the event loop). The set is the only state
held — **there is no reference to the running task**, so there is no mechanism to cancel it.

The LLM call (inside `run_conversation()`) runs to completion or until a network error; there is
no cooperative cancellation path. Once the turn starts, it runs.

### SSE transport — v4 pub/sub

v4 (T3 of `m3-agent-chat-v4`) introduces an **in-process `asyncio.Queue`-based pub/sub bus**
(`src/realtime/bus.py`): `GET /api/v1/threads/{id}/stream` fans out all events to every member
subscriber; the agent turn publishes token deltas and `hermes.tool.progress` frames to the topic
so every member watching sees the agent work live. The existing SSE event types after v4:
`message.created`, `agent.working`, token deltas, `hermes.tool.progress`,
`hermes.artifact.saved`, `member.changed`, `channel.deleted`, `typing`.

**`turn.stopped` does not exist** — there is no event that signals a cancelled turn. The FE has
no `agent.working` → stop path; once it sees the working indicator, it can only wait.

### digital-factory-ui — composer and agent state

`src/components/agent-chat/prompt-input.tsx` renders a `<textarea>` and a **Send button** only.
When the agent is working (signalled by `agent.working` on the SSE stream), the composer is
disabled but shows no alternate control. There is no Stop button, no cancel service call, and no
stopped-message rendering in `message.tsx`.

`HermesMessage` (`types.ts`) carries `finishReason` (forwarded from hermes `finish_reason`), but
the UI does not render any visual distinction for it. The `finish_reason` column already exists in
the hermes `messages` table (values: `'stop'`, `'length'`, `'tool_calls'`).

---

## 2. Problem Framing

### What must change

1. **hermes-agent — hold task references, not just session ids.**
   `_active_runs: set[str]` must become `dict[str, ActiveRun]` (holding the asyncio Task and
   triggering user id) so the cancel endpoint can call `task.cancel()` on the running turn.

2. **hermes-agent — a cancel endpoint.**
   A new `POST /api/v1/threads/{id}/cancel` route that looks up the running task, validates the
   caller is the triggering member, and calls `task.cancel()`.

3. **hermes-agent — CancelledError handling in the turn runner.**
   `_run_agent_turn` must catch `asyncio.CancelledError`, flush whatever tokens were accumulated,
   persist the partial message with `finish_reason='stopped'`, publish a `turn.stopped` event to
   the bus, and exit cleanly (not re-raise).

4. **digital-factory-ui — Stop button in the composer.**
   While `agentWorking` is true, the Send button is replaced by a **Stop** button. Clicking it
   calls the cancel endpoint. On `turn.stopped`, the partial message is marked stopped in the
   transcript and the composer re-enables.

### What must stay stable

- `_active_runs` 409 guard for concurrent turns (preserved — just upgraded to a dict).
- The v4 in-process pub/sub bus interface (`bus.publish`, `bus.subscribe`) — we add one event
  type (`turn.stopped`) but change nothing else.
- The v3 agent tools, authoring/approval pipeline, and `ApprovalCard`/`DocumentEditCard` — untouched.
- The BFF generic proxy — **no BFF change** (the new cancel endpoint is under `/bff/hermes-agent`
  and is forwarded automatically).
- `workflow-backend`, `user-service`, and `workflow-bff` — **no changes**.

### Fixed assumptions

- **hermes runs single-instance per workspace** (M2 model) — the `_active_runs` dict is in-process
  and authoritative. No cross-replica cancel routing needed for v4.
- `asyncio.Task.cancel()` delivers `CancelledError` at the next `await` point inside
  `run_conversation()` — the LLM call is `async`, so cancellation is timely.
- `X-User-Id` identifies the caller of the cancel endpoint (injected by the BFF, same as every
  other hermes route).

---

## 3. Options Considered

### 3.1 Stop signal transport (resolves product-spec OQ1)

**Option A — `POST /threads/{id}/cancel` HTTP endpoint (chosen).** A deliberate cancel is a write
action. A new endpoint under `/api/v1/threads/{id}/cancel` is forwarded by the BFF generic proxy
with identity injection and zero BFF change. Returns `202` (cancel accepted) or `404` (no active
turn). Simple, explicit, auditable.

**Option B — close the SSE stream as an implicit cancel.** The FE closes the `EventSource` →
server detects disconnect → treats it as a stop signal. Rejected: (a) conflates network drop with
deliberate stop — a reconnect after a flaky connection should not cancel the turn; (b) v4's
`?since=` replay on reconnect already handles reconnect without restart; (c) the SSE stream is
shared among all thread members, so closing one member's connection is ambiguous.

**Option C — WebSocket control message.** Rejected: `workflow-bff` returns HTTP 501 on WS upgrade
(`proxy_handler.go:75-77`) — established in v4 §3.1.

### 3.2 Server-side cancellation mechanism

**Option A — `asyncio.Task.cancel()` (chosen).** Upgrading `_active_runs` to hold the Task
reference allows `task.cancel()` to inject `CancelledError` at the next `await` inside
`run_conversation()`. The turn runner catches it, flushes partial output, persists the message,
and publishes the event. No new threading primitives; works with the existing asyncio event loop.

**Option B — cooperative cancellation via a shared `asyncio.Event`.** A per-session
`_cancel_events: dict[str, asyncio.Event]`; the agent loop polls `cancel_event.is_set()` between
tokens. Rejected: (a) requires adding polling to an inner loop that doesn't own the network
`await`; (b) `Task.cancel()` already interrupts at `await` boundaries, which is the same
granularity with less ceremony.

### 3.3 Partial message persistence (resolves product-spec OQ2)

**Option A — persist partial output with `finish_reason='stopped'`; discard if empty (chosen).**
hermes `messages` already has a `finish_reason` column. On `CancelledError`, the accumulated
token string is written as an assistant message with `finish_reason='stopped'`. If the cancel
arrived before any tokens were produced (empty string), nothing is persisted — a zero-token
stopped message has no value and creates a confusing empty bubble. The `turn.stopped` SSE event
carries `message_id: null` in this case so the FE can still reset state.

**Option B — always persist, even empty.** Rejected: an empty message bubble with a "stopped"
label is confusing. The record-keeping value is the partial text, not the stop event itself.

### 3.4 Who can stop a turn (resolves product-spec OQ3)

**Option A — triggering member only (chosen).** `_active_runs` stores `triggered_by: user_id`
alongside the Task. The cancel endpoint validates `X-User-Id == triggered_by`; any other member
gets 403. A member cannot disrupt another member's agent interaction — clear ownership.

**Option B — any thread member can stop.** Simpler to implement, but allows a thread member to
interrupt an interaction they didn't start. Rejected on ownership grounds.

---

## 4. Chosen Design

**Summary:** upgrade hermes's `_active_runs` to hold task references + triggering user; add
`POST /cancel`; catch `CancelledError` in the turn runner to flush and persist; add
`turn.stopped` to the SSE bus. On the FE, show the Stop button while `agentWorking`; on stop,
hit the cancel endpoint, handle the `turn.stopped` event, re-enable the composer.

### 4.1 hermes-agent — Task tracking + cancel endpoint [T1]

**`_active_runs` upgrade** (`src/api/routers/chat.py`, or its v4 successor in the send service):
```python
# Before
_active_runs: set[str]

# After
@dataclass
class ActiveRun:
    task: asyncio.Task
    triggered_by: str   # X-User-Id of the member who triggered this turn

_active_runs: dict[str, ActiveRun]   # session_id → ActiveRun
```
All existing 409-guard logic reads `session_id in _active_runs` — still correct. The only change
is that entry creation stores the task reference and triggering user.

**Cancel endpoint** (new, `src/api/routers/chat.py` or `threads.py`, `Depends(require_identity)`):
```
POST /api/v1/threads/{session_id}/cancel
  Validated by: X-User-Id == _active_runs[session_id].triggered_by (else 403)
  If no active run: 404 {"error": "no_active_turn"}
  Otherwise: _active_runs[session_id].task.cancel()
             return 202 {"status": "cancelling"}
```
The 202 is immediate — the actual turn halt is asynchronous (the task processes the
`CancelledError` on its next await).

**`_run_agent_turn` changes:**
```python
async def _run_agent_turn(session_id: str, user_id: str, ...):
    accumulated: list[str] = []
    try:
        async for frame in run_conversation(...):
            token = extract_token_text(frame)
            if token:
                accumulated.append(token)
            await bus.publish(session_id, frame)   # fan-out unchanged
    except asyncio.CancelledError:
        partial = "".join(accumulated)
        message_id = None
        if partial:   # only persist if any tokens generated (resolves OQ2)
            msg = await session_store.create_message(
                session_id=session_id,
                role="assistant",
                content=partial,
                author_id="agent",
                finish_reason="stopped",
            )
            message_id = str(msg.id)
        await bus.publish(session_id, {
            "type": "turn.stopped",
            "message_id": message_id,   # null if nothing was persisted
        })
        # Do NOT re-raise — the turn runner exits cleanly.
    finally:
        _active_runs.pop(session_id, None)
```

The `turn.stopped` event is treated as a terminal turn event by all subscribers (same as
`data: [DONE]` for a completed turn).

### 4.2 digital-factory-ui — Stop button + stopped-message rendering [T2]

**Composer state machine** (`src/components/agent-chat/prompt-input.tsx`):
- New prop: `isAgentWorking: boolean` (wired from the `agentWorking` state in `AgentChatPanel`,
  already set by the `agent.working` SSE event in v4 T6).
- When `isAgentWorking === true`: render a **Stop** button (square/stop icon) in place of Send.
  Disable the textarea.
- When `false`: render Send as normal.

**Stop action** (new fn in `src/services/hermes-agent/chat.ts`):
```ts
export async function cancelAgentTurn(threadId: string): Promise<void> {
  await apiFetch(`/bff/hermes-agent/api/v1/threads/${threadId}/cancel`, {
    method: "POST",
    credentials: "include",
  });
  // 202 = cancel accepted; 404 = no active turn (race — safe to ignore)
}
```

**SSE event handler** (in the stream event switch in `agent-chat-panel.tsx`):
```ts
case "turn.stopped":
  if (event.message_id) {
    setMessages(prev => prev.map(m =>
      m.id === event.message_id ? { ...m, finishReason: "stopped" } : m
    ));
  }
  setAgentWorking(false);
  break;
```

**Stopped-message rendering** (`src/components/agent-chat/message.tsx`):
When `message.finishReason === "stopped"`, append a muted trailing indicator after the message
content (e.g., `<span className="text-muted-foreground text-xs ml-1">— stopped</span>`). The rest
of the message renders normally (markdown, tool cards, etc.).

### 4.3 End-to-end flow

1. User sends `@agent …` → agent turn starts → `agent.working` published → FE sets
   `agentWorking=true` → **Stop button appears**.
2. User clicks **Stop** → `POST /threads/{id}/cancel` → hermes validates triggering member →
   `task.cancel()` → 202 returned immediately.
3. `CancelledError` raised inside `_run_agent_turn` at the next `await` → partial tokens flushed
   → message persisted with `finish_reason='stopped'` → `turn.stopped` published on the bus.
4. All subscribers receive `turn.stopped` → partial message marked stopped in each member's
   transcript → composer re-enabled.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| v4 in-process bus (`bus.publish`) — v4 T3 of `m3-agent-chat-v4` | v4 feature | `turn.stopped` publishes to the bus | **T1 blocked on v4 T3** |
| v4 decoupled send service (`_active_runs` in `POST /threads/{id}/messages`) — v4 T2 | v4 feature | T1 upgrades the `_active_runs` introduced in v4 T2 | **T1 must coordinate with v4 T2** |
| `messages.finish_reason` column | Existing | ✅ in hermes schema (`001_initial_schema.sql`) | No |
| BFF generic proxy forwarding `/bff/hermes-agent/api/v1/threads/*/cancel` | Existing | ✅ prefix match auto-forwards with identity | No BFF change |
| `require_identity` + `X-User-Id` injection | Existing | ✅ all hermes routes; new route inherits | No |
| `@microsoft/fetch-event-source` SSE client | Existing | ✅ used in v4 T6 for the persistent subscription | No |
| `agentWorking` state wired from `agent.working` event | v4 T6 of `m3-agent-chat-v4` | Required for T2's Stop button display condition | **T2 blocked on v4 T6** |
| `workflow-backend`, `user-service`, `workflow-bff` | Existing | No change | No |

**Key sequencing constraint:** Implement this feature after v4 T2 and T3 land in `hermes-agent`,
and after v4 T6 lands in `digital-factory-ui`. The changes are strictly additive on top of v4.

---

## 6. Parallelization / Blocking Analysis

```
[External prerequisites: v4 T2 + T3 must be merged into hermes-agent before T1 can begin]
[External prerequisite:  v4 T6 must be merged into digital-factory-ui before T2 can integrate]

T1: hermes-agent — _active_runs set → ActiveRun dict; POST /threads/{id}/cancel endpoint;
                   CancelledError handler (partial flush + finish_reason='stopped' persist +
                   turn.stopped bus publish)
  └── BLOCKED on v4 T2 (decoupled send service — owns the _active_runs we upgrade)
  └── BLOCKED on v4 T3 (in-process bus — turn.stopped publishes to it)
  │
  T2: digital-factory-ui — Stop button in prompt-input.tsx (shown when isAgentWorking);
                           cancelAgentTurn() service fn; turn.stopped SSE event handler;
                           stopped finishReason indicator in message.tsx
      └── BLOCKED on T1 (cancel endpoint + turn.stopped event shape)
      └── BLOCKED on v4 T6 (agentWorking state wired from agent.working)
```

T1 and T2 are sequential. Both are small (~100 and ~60 lines respectively). Total effort after
the v4 prerequisites land: two fast tasks.

---

## 7. Repository Impact

| Repo (`workspace.yaml` id) | Task | Changes | Why |
|---|---|---|---|
| `hermes-agent` | T1 | `_active_runs` set → `dict[str, ActiveRun]`; `ActiveRun` dataclass; `POST /api/v1/threads/{id}/cancel` route; `_run_agent_turn` `CancelledError` handler (partial flush + `finish_reason='stopped'` + `turn.stopped` bus publish) | Server-side cancellation: task reference, stop endpoint, clean partial-message exit |
| `digital-factory-ui` | T2 | `prompt-input.tsx` Stop button (conditional on `isAgentWorking`); `chat.ts` `cancelAgentTurn()` service fn; `agent-chat-panel.tsx` `turn.stopped` event handler; `message.tsx` stopped-message indicator | Stop affordance, user feedback, state reset |
| `workflow-bff` | — | **none** (new route auto-proxied) | — |
| `workflow-backend` | — | **none** | — |
| `user-service` | — | **none** | — |

---

## 8. Validation and Release Impact

### Testing

**T1 (hermes-agent):**
- Cancel with no active turn → `404 {"error": "no_active_turn"}`.
- Cancel by non-triggering thread member → `403`.
- Cancel by triggering member during active turn → `202`; `CancelledError` raised; partial message
  persisted with `finish_reason='stopped'`; `turn.stopped` published on the bus; `_active_runs`
  entry cleaned up.
- Cancel before any tokens generated → `202`; no message persisted; `turn.stopped` with
  `message_id: null`.
- Race: turn completes naturally just before cancel arrives → `_active_runs` already empty → `404`
  (safe — the turn already finished).
- After a successful stop, the session is free for a new turn immediately.

**T2 (digital-factory-ui):**
- Stop button visible when `isAgentWorking === true`; Send visible otherwise.
- Stop button click calls `cancelAgentTurn(threadId)`; subsequent clicks are no-ops (404 ignored).
- `turn.stopped` with `message_id` → message gains stopped indicator; `agentWorking` reset.
- `turn.stopped` with `message_id: null` → `agentWorking` reset; no message update.
- v3 `ApprovalCard` and `DocumentEditCard` still render in feature threads (no regression).
- After stop, the composer is enabled and the user can send the next message.

### Migration / Config

- **No DB schema change.** `finish_reason='stopped'` is a new value in an existing column — no
  migration needed.
- **No new env vars, no new infrastructure.**
- **No `workspace.yaml` or BFF change.**

### Rollout

Fully additive. Ship T1 (hermes) first; T2 (FE) follows. During the window between T1 and T2
deploys, the cancel endpoint exists but the FE has no button — harmless. Existing clients that
don't handle `turn.stopped` events ignore them (event switch falls through).

### Backward Compatibility

- `_active_runs` dict is a drop-in for the set: `session_id in _active_runs` works identically.
- `turn.stopped` is an additive SSE event type; older FE versions receive and ignore it.
- `finish_reason='stopped'` is a new value in the existing column; queries filtering on `'stop'`
  or `'length'` are unaffected.

## Resolved Decisions (formerly open questions in product spec)

- **OQ1 — Stop signal transport → `POST /threads/{id}/cancel`.** HTTP endpoint through the BFF
  generic proxy; zero BFF change; 202 on accept, 404 if no active turn.
- **OQ2 — Zero-token partial → not persisted.** Only persist a stopped message if at least one
  token was generated. `turn.stopped` carries `message_id: null` in the empty case.
- **OQ3 — Who can stop (multi-member thread) → triggering member only.** `_active_runs` stores
  `triggered_by: user_id`; non-triggering members receive 403 on the cancel endpoint.

## Design Assets (no Figma)

The product spec contains no Figma URLs. The frontend task (T2) requires no `### Figma`
subsection. If designs are added later, add a `## Figma` section here and update T2.

## Reference

- Product spec: `docs/features/m3-stop-agent-chat/product-spec.md`
- v4 architecture (transport, bus, send service, `_active_runs` guard):
  `docs/features/m3-agent-chat-v4/technical-design.md` §3.1 / §3.3 / §4.2 / §4.3
- v3 turn runner and SSE envelope:
  `docs/features/m3-agent-chat-v3/technical-design.md` §1 / §4.1
- Touched repos:
  - `hermes-agent`: `src/api/routers/chat.py` (or v4 successor), `src/realtime/bus.py` (v4),
    `src/db/models.py`, `src/streaming/sse.py`
  - `digital-factory-ui`: `src/components/agent-chat/prompt-input.tsx`,
    `src/components/agent-chat/agent-chat-panel.tsx`, `src/components/agent-chat/message.tsx`,
    `src/services/hermes-agent/chat.ts`
