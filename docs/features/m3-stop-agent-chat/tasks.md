# Task Breakdown — m3-stop-agent-chat

**Feature status:** `in_tdd` | **Stage:** `tasks` (awaiting approval)
Machine state lives in `tasks/T<n>.yaml`. This file is narrative only — do not add status, log,
or PR fields here.

---

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | hermes-agent — cancel endpoint + Task tracking + CancelledError handler | — (external: v4 T2 + T3 must be merged first) |
| T2 | 2 | digital-factory-ui — Stop button + stopped-message rendering | T1 (external: v4 T6 must be merged first) |

---

## T1 — hermes-agent — cancel endpoint + Task tracking + CancelledError handler

### Description

Adds server-side cancellation support to hermes-agent. Today `_active_runs` is an in-process
`set[str]` keyed by session id — it guards against concurrent turns but holds no reference to
the running asyncio Task, making cancellation impossible.

This task upgrades the turn-runner machinery and adds a dedicated cancel endpoint:

1. **`_active_runs` upgrade** — Change `set[str]` to `dict[str, ActiveRun]` where `ActiveRun`
   is a small dataclass holding `task: asyncio.Task` and `triggered_by: str` (the `X-User-Id`
   of the member who triggered the turn). All existing 409-guard reads (`session_id in
   _active_runs`) continue to work identically.

2. **`POST /api/v1/threads/{session_id}/cancel`** — New route (`Depends(require_identity)`).
   - Validates `X-User-Id == _active_runs[session_id].triggered_by` — other members receive 403.
   - If no active run: 404 `{"error": "no_active_turn"}`.
   - Calls `_active_runs[session_id].task.cancel()`, returns 202 `{"status": "cancelling"}`.
   - Forwarded automatically by the BFF generic proxy — no BFF change.

3. **`_run_agent_turn` — `CancelledError` handler** — Wrap the agent iteration in
   `try/except asyncio.CancelledError`:
   - Accumulate tokens into a local list as the turn runs.
   - On `CancelledError`: join the accumulated tokens; if non-empty, persist an assistant
     message with `finish_reason='stopped'`; publish `turn.stopped` to the v4 in-process bus
     (`bus.publish(session_id, {"type": "turn.stopped", "message_id": msg.id | None})`).
   - Do **not** re-raise — the turn runner exits cleanly.
   - `finally`: always pop `session_id` from `_active_runs`.

**External prerequisite (not a YAML depends_on — cross-feature):** v4 T2 (decoupled send service,
which owns `_active_runs`) and v4 T3 (in-process bus `bus.publish`) from `m3-agent-chat-v4` must
be merged into `hermes-agent` before this task can begin. Verify with the human before claiming.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Confirm v4 T2 + T3 are merged into `hermes-agent:main` before starting
- [ ] Define `ActiveRun` dataclass (`task: asyncio.Task`, `triggered_by: str`)
- [ ] Change `_active_runs` set → `dict[str, ActiveRun]`; update entry creation to store task + triggered_by
- [ ] Add `POST /api/v1/threads/{session_id}/cancel` route with `require_identity`
- [ ] Implement 403 check (non-triggering member), 404 (no active run), 202 (cancel accepted)
- [ ] Add `try/except asyncio.CancelledError` in `_run_agent_turn`; accumulate tokens; flush on cancel
- [ ] Persist partial message with `finish_reason='stopped'` when non-empty
- [ ] Publish `turn.stopped` event to bus (`message_id` or null)
- [ ] Add `finally: _active_runs.pop(session_id, None)` to ensure cleanup on all exit paths
- [ ] Test: cancel with no active turn → 404
- [ ] Test: cancel by non-triggering member → 403
- [ ] Test: cancel mid-turn → 202; partial message persisted with `finish_reason='stopped'`; `turn.stopped` published
- [ ] Test: cancel before any tokens → 202; no message persisted; `turn.stopped` with `message_id: null`
- [ ] Test: natural turn completion after prior cancel → session not stuck in `_active_runs`
- [ ] Run full hermes-agent test suite + lint (Python) — zero errors before PR

---

## T2 — digital-factory-ui — Stop button + stopped-message rendering

### Description

Adds the Stop button UI and stopped-message rendering to `digital-factory-ui`. This is the
user-facing surface of the cancellation feature.

1. **Stop button in `prompt-input.tsx`** — Add a new prop `isAgentWorking: boolean`. When true,
   render a **Stop** button (square/stop icon) in place of the Send button and disable the
   textarea. When false, show Send as normal. Wire `isAgentWorking` from the `agentWorking`
   state in `AgentChatPanel` (already set by the `agent.working` SSE event from v4 T6).

2. **`cancelAgentTurn()` service fn** (`src/services/hermes-agent/chat.ts`) — A simple
   `POST /bff/hermes-agent/api/v1/threads/${threadId}/cancel` with `credentials: "include"`.
   Returns void; 404 (race — turn finished naturally) is ignored.

3. **`turn.stopped` SSE event handler** (`agent-chat-panel.tsx`) — In the stream event switch:
   - If `event.message_id` is non-null: update the messages list to set
     `finishReason: "stopped"` on the matching message.
   - Always: `setAgentWorking(false)` to re-enable the composer.

4. **Stopped-message indicator** (`message.tsx`) — When `message.finishReason === "stopped"`,
   append a muted trailing label after the message content (e.g.,
   `<span className="text-muted-foreground text-xs ml-1">— stopped</span>`). Everything else
   (markdown rendering, tool cards, ApprovalCard, DocumentEditCard) renders unchanged.

**External prerequisite (not a YAML depends_on — cross-feature):** v4 T6 from `m3-agent-chat-v4`
must be merged into `digital-factory-ui` before this task can begin (provides `agentWorking`
state wired from the `agent.working` SSE event and the persistent subscription). Verify with the
human before claiming.

### Required skills
- frontend-engineer
- typescript-best-practices
- nextjs-best-practices
- heroui-react

### Subtasks
- [ ] Confirm v4 T6 is merged into `digital-factory-ui:main` before starting
- [ ] Add `isAgentWorking: boolean` prop to `prompt-input.tsx`; conditionally render Stop / Send
- [ ] Add `cancelAgentTurn(threadId)` to `src/services/hermes-agent/chat.ts`
- [ ] Wire Stop button `onClick` → `cancelAgentTurn`; ignore 404 response
- [ ] Add `turn.stopped` case in the SSE event switch in `agent-chat-panel.tsx`
- [ ] On `turn.stopped`: update messages list (`finishReason: "stopped"` on matched id); reset `agentWorking`
- [ ] Add stopped-message indicator in `message.tsx` (muted trailing label when `finishReason === "stopped"`)
- [ ] Verify v3 `ApprovalCard` and `DocumentEditCard` still render correctly in feature threads
- [ ] Test: Stop button visible when `isAgentWorking=true`; Send visible otherwise
- [ ] Test: clicking Stop calls cancel endpoint; subsequent clicks produce no double-fire
- [ ] Test: `turn.stopped` with `message_id` → message shows stopped indicator; composer re-enabled
- [ ] Test: `turn.stopped` with `message_id: null` → composer re-enabled; no message update
- [ ] Run full digital-factory-ui test suite + lint/type-check — zero errors before PR
