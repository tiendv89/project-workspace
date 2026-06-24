# Product Specification

## Feature
- Feature ID: `m4-agent-cost`
- Title: Agent Cost Tracking — Token Usage and Cost Visibility

## Background

The M3 agent-chat line now delivers a full team-chat surface with triggered agent dispatch,
real-time delivery, and a stop mechanism. Every agent turn calls the Claude API from the
`hermes-agent` process and consumes tokens — input tokens, output tokens, and cache tokens.
Today that usage is **invisible**: there is no record of what a turn costs, no per-session
accumulation, and no cost surface in the UI.

M4 is scoped as "Meter & Monetize" — metering ledger, credits, tiers, spend caps, and per-
workspace cost dashboard. None of that is buildable without first capturing the raw cost
signal: **what did this agent turn cost, in tokens and dollars, on this model at this moment?**

This feature delivers the **cost capture and visibility layer** — the measurement foundation
that M4's billing engine will build on. It is deliberately scoped to *read*: capture, store,
and display. Billing, caps, credits, and enforcement are M4 proper and are explicitly excluded.

The agent runtime (task-execution workers in the workflow orchestrator) will eventually need
the same signal. This feature designs the data model and reporting API with that extension
in mind, so the runtime wiring is additive, not a rebuild.

## Problem

### Token costs are invisible

Every agent chat turn fires one or more Claude API calls and receives a `usage` block in the
response — `input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`. Today `hermes-agent` discards this data; nothing is stored and
nothing is surfaced to the user or the workspace operator.

### M4's metering engine has nothing to meter

M4's core deliverables — metering ledger, credits, caps, dashboards — all assume a stream of
cost events to consume. Without a cost-capture layer there is no event stream: the billing
engine would have nothing to aggregate, enforce, or invoice. The measurement layer must land
first.

### Agent runtime costs are equally invisible

Implementation agents, reviewer agents, and fix agents in the workflow orchestrator all
consume tokens on every run. This usage is also discarded today. The cost structure of a
task execution (model used, phases, total tokens) is unknown, which makes any future cost
model for the runtime purely speculative.

### Users have no cost awareness

A user running multiple agent sessions has no idea whether they are consuming $0.10 or $10.00
worth of API calls. The absence of any cost signal makes usage feel "free" until it suddenly
isn't — a trust and UX problem that becomes acute when M4 introduces any kind of cap or credit.

## Goals

- **G1 — Capture token usage per agent turn.** Each completed or stopped agent chat turn
  records its token usage from the Claude API response: `input_tokens`, `output_tokens`,
  `cache_read_tokens`, `cache_write_tokens`, `model_id`, and timestamp. A stopped turn records
  the tokens consumed up to the cancellation point.
- **G2 — Calculate cost per turn.** Convert raw token counts to USD using a per-model pricing
  table stored in the backend. Pricing rows contain `input_cost_per_mtok`,
  `output_cost_per_mtok`, `cache_read_cost_per_mtok`, `cache_write_cost_per_mtok`.
  `cost_usd` is derived at write time and stored alongside raw counts.
- **G3 — Aggregate cost per session.** Each session maintains a running `total_cost_usd`
  updated on every new turn cost record. The aggregate is incrementally maintained, not
  recomputed on read.
- **G4 — Display cost in the chat UI.** Each agent message card shows its cost (`$0.0023`).
  The session / thread header shows the running session total. Cost is always visible but
  secondary — typography stays small, non-prominent.
- **G5 — Expose cost query API.** `workflow-bff` exposes endpoints to query per-turn costs
  and session-level totals. The API is designed to generalize beyond chat: any cost producer
  (agent runtime task, future tool runs) can write a cost record against the same store and
  appear in the same query surface.
- **G6 — Design for runtime extension.** The cost record schema carries a `source_type`
  discriminator (`chat_turn` | `task_run` | future values) and a nullable `task_id`, so
  agent-runtime cost wiring in a later feature is additive — no schema migration, no API
  change. The pricing table is shared.

## Non-goals

- **NG1 — No billing, caps, or enforcement.** Spend caps, auto-pause, credit deduction, and
  tier enforcement are M4's core deliverables and are explicitly out of scope here. This
  feature measures; M4 bills.
- **NG2 — No BYO key or model-gateway managed mode.** Per-key or per-org cost allocation and
  gateway-managed API routing are separate enabling track concerns.
- **NG3 — No metering of human actions.** Only LLM API calls generate cost records. Human
  messages, approvals, file edits, and lifecycle transitions are not metered.
- **NG4 — No retroactive backfill.** Historical turns before this feature ships carry no cost
  records. Cost data starts from the deploy date.
- **NG5 — No agent-runtime wiring in this feature.** The data model supports runtime cost
  records (`source_type: task_run`), but the hermes-worker-to-backend pipeline for task runs
  is a separate follow-on feature. This feature wires only the agent-chat path.
- **NG6 — No cost export, invoice download, or admin dashboard.** Per-workspace cost
  dashboards and invoice generation are M4 proper.
- **NG7 — No cost attribution to individual users across sessions.** Per-user lifetime spend
  aggregates and cross-session cost reports are M4 proper.

## User Flows

### Watching a turn cost appear

1. A user sends `@agent draft the spec from what we agreed`.
2. The agent begins generating; the message input shows the "agent is working" indicator.
3. The agent finishes. Its message card appears in the thread with attribution and a small
   cost badge: *$0.0041*.
4. The session header updates from *Session cost: $0.021* to *Session cost: $0.025*.

### Stopping a turn and seeing the partial cost

1. The user sends a long `@agent` trigger and mid-generation clicks **Stop**.
2. The partial response appears in the thread, marked *— stopped by user*.
3. The cost badge shows the tokens consumed up to the stop: *$0.0009*.
4. The session total reflects the partial cost.

### Workspace operator checking session costs (future-readiness)

1. M4's billing dashboard (out of scope here) will call the cost query API to produce a
   per-workspace, per-session cost breakdown.
2. The API shape delivered by this feature is what M4 will consume — no rework needed.

## Scope

### In scope

**Cost capture (hermes-agent)**
- After every agent turn completion or stop, extract the `usage` block from the Claude API
  response and emit a cost event to `workflow-bff`.
- The event carries: `session_id`, `turn_id`, `model_id`, `input_tokens`, `output_tokens`,
  `cache_read_tokens`, `cache_write_tokens`, `stopped` (bool), `timestamp`.
- Stopped turns emit the event with `stopped: true` and whatever token counts the API
  returned up to cancellation.

**Cost storage and pricing (workflow-backend)**
- A `model_pricing` table: `model_id`, `input_cost_per_mtok`, `output_cost_per_mtok`,
  `cache_read_cost_per_mtok`, `cache_write_cost_per_mtok`, `effective_from`, `effective_to`.
  Seeded with current Anthropic pricing for Haiku 4.5, Sonnet 4.6, Opus 4.8, Fable 5.
- A `turn_cost` table: `id`, `session_id`, `turn_id`, `source_type` (default `chat_turn`),
  `task_id` (nullable), `model_id`, `input_tokens`, `output_tokens`, `cache_read_tokens`,
  `cache_write_tokens`, `cost_usd`, `stopped`, `created_at`.
- Increment `sessions.total_cost_usd` on every new `turn_cost` insert (trigger or
  application-layer).
- A `model_pricing` admin seed migration.

**Cost API (workflow-bff)**
- `POST /sessions/:id/turn-costs` — receive and persist a cost event from `hermes-agent`.
- `GET /sessions/:id/cost` — return `{ total_cost_usd, turn_count, turns: [{turn_id,
  cost_usd, model_id, tokens, stopped}] }`.
- Both endpoints require workspace-scoped auth (existing session auth).

**Cost display (digital-factory-ui)**
- Agent message card: add a small cost badge (`$0.0041`) below the message content.
  Stopped messages show the badge alongside the stopped indicator.
- Session / thread header: add a running total display (`Session cost: $0.025`).
  Updates reactively as new turn costs arrive.
- Cost values fetched as part of the existing session message query; no separate polling.

### Out of scope (tracked separately)

- Agent-runtime (task-execution) cost wiring — follow-on, same schema, different producer.
- Billing, caps, credits, enforcement — M4 proper.
- Cross-session / per-user aggregate reports and admin dashboard — M4 proper.
- BYO key / gateway-managed cost allocation.

## Data Model

```
model_pricing
├── model_id           TEXT PK
├── input_cost_per_mtok      NUMERIC  (cost in USD per million input tokens)
├── output_cost_per_mtok     NUMERIC
├── cache_read_cost_per_mtok NUMERIC
├── cache_write_cost_per_mtok NUMERIC
├── effective_from     TIMESTAMPTZ
└── effective_to       TIMESTAMPTZ (null = current)

turn_cost
├── id                 UUID PK
├── session_id         UUID FK → sessions
├── turn_id            UUID FK → messages (the agent message this turn produced)
├── source_type        TEXT  ('chat_turn' | 'task_run')   -- extensibility discriminator
├── task_id            UUID nullable                       -- populated by runtime wiring later
├── model_id           TEXT FK → model_pricing
├── input_tokens       INTEGER
├── output_tokens      INTEGER
├── cache_read_tokens  INTEGER
├── cache_write_tokens INTEGER
├── cost_usd           NUMERIC(12,8)
├── stopped            BOOLEAN DEFAULT false
└── created_at         TIMESTAMPTZ DEFAULT now()

sessions (addition)
└── total_cost_usd     NUMERIC(12,8) DEFAULT 0
```

## Open Questions

None — all scoping decisions are locked.

## Success Criteria

- Every completed or stopped agent chat turn produces a `turn_cost` record with correct
  token counts and a non-zero `cost_usd`.
- The session `total_cost_usd` equals the sum of all its `turn_cost.cost_usd` rows.
- The agent message card in the UI displays the per-turn cost immediately after the turn
  completes (or stops).
- The session header shows the running total and updates after each new turn.
- The cost query API (`GET /sessions/:id/cost`) returns the correct per-turn and session
  totals for any session with recorded turns.
- A `model_pricing` seed migration contains current Anthropic pricing for Haiku 4.5,
  Sonnet 4.6, Opus 4.8, and Fable 5.
- The `turn_cost.source_type` and `turn_cost.task_id` columns are present and nullable,
  confirming the runtime extension path is ready.
- Lint, type-check, and the full test suites of all touched repos pass before any PR.

## References

- Roadmap: `docs/roadmap-milestone.md` → **M4 — Meter & Monetize** (metering ledger, model
  gateway, credits + per-model conversion table, tier ladder, spend caps, cost dashboard).
  This feature delivers the raw cost signal M4's billing engine will consume.
- Stop-agent-chat: `docs/features/m3-stop-agent-chat/` — defines the stopped-turn event
  that this feature must also capture cost for.
- Agent chat v4: `docs/features/m3-agent-chat-v4/` — defines the real-time thread surface
  where per-turn cost badges will be displayed.
- Anthropic pricing reference: https://www.anthropic.com/pricing (seed data source for
  `model_pricing`).
- Touched repos: `hermes-agent` (cost event emission), `workflow-backend` (schema +
  pricing table), `workflow-bff` (cost API), `digital-factory-ui` (cost badges + session
  total).
