# Task Breakdown — m3-agent-cta

Feature status: `in_tdd` | Stage: `tasks` (awaiting approval)
Machine state (status, branch, PR, log) lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Hermes agent — suggest_next_actions tool + DB migration | — |
| T2 | 1 | BFF — workspace capabilities endpoint | — |
| T3 | 2 | Frontend — CTA card components + integration | T1, T2 |
| T4 | 3 | Hermes agent (hermes-agent): suggest_next_actions tool + DB migration [fix T1 wrong repo] | — |
| T5 | 3 | Frontend: remove WorkspaceCapabilities gating — show all CTA starters by default | — |

## Dependency diagram

```
T1: suggest_next_actions tool + DB migration   [workflow-backend] ← WRONG REPO (done but in wrong repo)
T2: workspace capabilities endpoint            [workflow-bff]     ← done
T3: CTA card components + integration          [digital-factory-ui] ← done

T4: suggest_next_actions tool + DB migration   [hermes-agent]    ← fixes T1 wrong repo
  └── Can begin now — no blockers
```

---

## T1 — Hermes agent: suggest_next_actions tool + DB migration

### Description

Register a new `suggest_next_actions` tool in the Hermes tool registry. The agent calls this
tool at the end of a turn when a natural next action exists. The executor handles the call
locally — no external API hit:

1. Validates the `suggestions` payload against the `CtaSuggestion` JSON schema.
2. Persists the suggestions to a new `messages.cta_suggestions JSONB` column.
3. Publishes a `turn.cta_suggestions` event on the in-process SSE bus.
4. Returns `{"status": "ok"}` to the agent so the turn ends cleanly.

Also extends the Hermes system prompt with guidance on when and how to call
`suggest_next_actions` (including examples for lifecycle and clarifying CTAs).

### Required skills

- backend-engineer
- python-best-practices
- postgres-best-practices

### Subtasks

- [ ] Write Alembic migration: `ALTER TABLE messages ADD COLUMN cta_suggestions JSONB NOT NULL DEFAULT '[]'::jsonb`
- [ ] Define `CtaSuggestion` schema in `tools/suggest_next_actions.py` with `category` enum and `maxItems: 3`
- [ ] Register tool in the Hermes tool registry alongside existing tools (e.g. `save_artifact`)
- [ ] Implement executor local handler: validate → persist → `bus.publish(session_id, {type: "turn.cta_suggestions", message_id, suggestions})` → return `{"status": "ok"}`
- [ ] Extend Hermes system prompt: when to call, when to omit, `action_text` format rules, `button_label` length constraint
- [ ] Unit test: handler persists correct JSON and publishes the event
- [ ] Unit test: schema validation rejects `> 3` suggestions and invalid `category` values
- [ ] Integration test: full agent turn with CTA tool call → `messages.cta_suggestions` populated + SSE event received

---

## T2 — BFF: workspace capabilities endpoint (SSE passthrough only — capabilities endpoint is dead code, frontend call removed by T5)

### Description

Add a new `GET /api/v1/workspace/capabilities` route to the BFF. The endpoint reads its own
runtime environment to determine which optional agent tools are configured and returns a
simple boolean JSON payload:

```json
{ "gitnexus": true, "rag": false }
```

- `gitnexus`: `true` when `GITNEXUS_MCP_URL` is set and non-empty in the BFF environment.
- `rag`: `true` when `MCP_RAG_URL` is set and non-empty.

No auth or per-user check required (capability presence is not a secret). Response is safe
to cache for the session lifetime on the client.

Also verify that the existing BFF SSE proxy forwards `turn.cta_suggestions` events
generically — the proxy should already be event-type-agnostic; document the finding and
add a test if it requires any change.

### Required skills

- backend-engineer
- python-best-practices

### Subtasks

- [ ] Add `GET /api/v1/workspace/capabilities` route returning `{"gitnexus": bool, "rag": bool}`
- [ ] Resolve `GITNEXUS_MCP_URL` and `MCP_RAG_URL` from the BFF environment (os.environ)
- [ ] Verify SSE proxy is event-type-agnostic; add test if not already covered
- [ ] Unit test: endpoint returns `true` when env var is set, `false` when absent or empty
- [ ] Integration test: endpoint reachable under existing auth model

---

## T3 — Frontend: CTA card components + integration

### Description

Implement the full CTA surface in `digital-factory-ui`:

**Post-reply CTA row**: Handle the `turn.cta_suggestions` SSE event in the chat store slice,
attaching suggestions to the relevant message. Render a `CTASuggestionRow` below the assistant
bubble after the turn ends (`[DONE]` received). Cards fade in on arrival. Past-turn cards
(from history re-hydration) render as inert (disabled, `opacity-50`). Clicking an active card
clears any composer draft and submits `action_text` as the next user message.

**Empty-state starters**: `EmptyStateCTARow` shown when a thread has zero messages.
Fetches `GET /api/v1/workspace/capabilities` on mount, reads the feature's lifecycle stage
from existing feature context, and maps stage → 1–2 lifecycle starter cards + gated capability
starters. Dismissed when the first message is sent or a card is clicked.

### Required skills

- frontend-engineer
- typescript-best-practices
- heroui-react

### Subtasks

- [ ] Define `CtaSuggestion` and `WorkspaceCapabilities` TypeScript interfaces
- [ ] Extend chat store slice: handle `turn.cta_suggestions` event → `setMessageCtas({messageId, ctas})`; hydrate from `message.cta_suggestions` on history load
- [ ] Build `CTACard` component: `active` / inert variants (disabled button + `opacity-50` on inert), icon, title, category chip, description, action button
- [ ] Build `CTASuggestionRow`: horizontal flex row on desktop, vertical stack < 768 px, fade-in CSS transition after turn complete
- [ ] Wire `CTASuggestionRow` into the message bubble: render after `[DONE]` received, not mid-stream (AC8)
- [ ] Click handler: `setInputDraft('')` → `submitMessage(actionText)` → dismiss/gray the row
- [ ] Build `EmptyStateCTARow`: fetch capabilities on mount, map feature stage to starters per spec table, suppress GitNexus/RAG starters when capability is `false`
- [ ] Dismiss `EmptyStateCTARow` on first `message.created` event or card click (ephemeral UI state, not persisted)
- [ ] Component tests: active vs inert `CTACard`; `CTASuggestionRow` mobile stacking; stage-to-starters mapping; capability gating
- [ ] E2E test: click CTA → message submitted → CTA row grayed out
- [ ] Visual regression: past-turn inert cards; mobile layout at 767 px

---

## T4 — Hermes agent (hermes-agent): suggest_next_actions tool + DB migration [fix T1 wrong repo]

### Description

T1 was implemented in `workflow-backend` — the wrong repository. The `suggest_next_actions` tool,
its executor handler, the `messages.cta_suggestions` DB migration, and the system prompt extension
all belong in `hermes-agent` where the Hermes agent actually runs.

This task re-implements the full T1 scope in `hermes-agent`. The work is identical to T1 in
substance; only the target repo differs. Reference T1's merged PR (https://github.com/tiendv89/workflow-backend/pull/45)
for the exact implementation to port.

1. Validates the `suggestions` payload against the `CtaSuggestion` JSON schema.
2. Persists the suggestions to a new `messages.cta_suggestions JSONB` column.
3. Publishes a `turn.cta_suggestions` event on the in-process SSE bus.
4. Returns `{"status": "ok"}` to the agent so the turn ends cleanly.

### Required skills

- backend-engineer
- python-best-practices
- postgres-best-practices

### Subtasks

- [ ] Write Alembic migration: `ALTER TABLE messages ADD COLUMN cta_suggestions JSONB NOT NULL DEFAULT '[]'::jsonb`
- [ ] Define `CtaSuggestion` schema in `tools/suggest_next_actions.py` with `category` enum and `maxItems: 3`
- [ ] Register tool in the Hermes tool registry alongside existing tools (e.g. `save_artifact`)
- [ ] Implement executor local handler: validate → persist → `bus.publish(session_id, {type: "turn.cta_suggestions", message_id, suggestions})` → return `{"status": "ok"}`
- [ ] Extend Hermes system prompt: when to call, when to omit, `action_text` format rules, `button_label` length constraint
- [ ] Unit test: handler persists correct JSON and publishes the event
- [ ] Unit test: schema validation rejects `> 3` suggestions and invalid `category` values
- [ ] Integration test: full agent turn with CTA tool call → `messages.cta_suggestions` populated + SSE event received

---

## T5 — Frontend: remove WorkspaceCapabilities gating — show all CTA starters by default

### Description

Design decision: `WorkspaceCapabilities` is removed. T3 implemented `EmptyStateCTARow` to fetch
`GET /api/v1/workspace/capabilities` on mount and suppress GitNexus/RAG starters when the
respective capability flag is `false`. This gating is no longer required — all starters show
by default regardless of deployment configuration.

Changes:
1. Remove the `WorkspaceCapabilities` TypeScript interface.
2. Remove the `GET /api/v1/workspace/capabilities` fetch call from `EmptyStateCTARow`.
3. Remove capability gating logic — always render GitNexus and RAG starters unconditionally.
4. Update component tests that asserted gating behaviour.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Delete `WorkspaceCapabilities` interface
- [ ] Remove `useEffect` / fetch call for `/api/v1/workspace/capabilities` in `EmptyStateCTARow`
- [ ] Remove `capabilities` prop/state and all conditional rendering based on it
- [ ] GitNexus and RAG starters always rendered — no capability check
- [ ] Update component tests: remove capability-gating assertions, verify all starters render unconditionally
