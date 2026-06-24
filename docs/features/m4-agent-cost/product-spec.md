# Product Specification

## Feature
- Feature ID: `m4-agent-cost`
- Title: Agent Cost Tracking — Credits, Usage Visibility, and Quota

## Background

The M3 agent-chat line now delivers a full team-chat surface with triggered agent dispatch,
real-time delivery, and a stop mechanism. Every agent turn calls the Claude API from the
`hermes-agent` process and consumes tokens — input tokens, output tokens, and cache tokens.
Today that usage is **invisible**: there is no record of what a turn costs, no per-session
accumulation, and no cost surface in the UI.

M4 is scoped as "Meter & Monetize" — metering ledger, credits, tiers, spend caps, and per-
workspace cost dashboard. None of that is buildable without first capturing the raw cost
signal and expressing it in a unit users actually see.

This feature delivers three things that M4's billing engine will build on:
1. **Cost capture** — token usage per agent turn, converted to **credits** (not raw USD).
   Credits are the user-facing unit; USD stays internal for accounting only.
2. **Cost storage owned by `user-service`** — the service that already holds user identity
   and workspace membership is the right home for per-user cost and quota state. Keeping it
   there avoids scattering usage accounting across multiple services.
3. **Daily and weekly quota** — each user gets a credit allowance that refreshes on a daily
   and weekly schedule, matching the pattern established by Claude's own usage limits. For
   now the cap is a fixed system-wide number; the billing plan will parameterize it in M4.

The agent runtime (task-execution workers in the workflow orchestrator) will eventually need
the same signal. This feature designs the data model with that extension in mind.

## Problem

### Token costs are invisible

Every agent chat turn fires one or more Claude API calls and receives a `usage` block in the
response — `input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`. Today `hermes-agent` discards this data; nothing is stored and
nothing is surfaced to the user or the workspace operator.

### M4's metering engine has nothing to meter

M4's core deliverables — metering ledger, credits, caps, dashboards — all assume a stream of
cost events. Without a cost-capture layer there is no event stream: the billing engine would
have nothing to aggregate, enforce, or invoice. The measurement layer must land first.

### Agent runtime costs are equally invisible

Implementation agents, reviewer agents, and fix agents in the workflow orchestrator all
consume tokens on every run. This usage is also discarded today, making any future cost
model for the runtime purely speculative.

### Users have no cost awareness and no quota signal

A user has no idea how many credits an agent session consumes, and no visibility into how
much of their daily or weekly allowance is left. The absence of a quota signal means the
first time a user hits a limit is a surprise — a trust and UX problem that becomes acute
the moment M4 introduces any kind of cap or credit enforcement.

## Goals

- **G1 — Capture token usage per agent turn.** Each completed or stopped agent chat turn
  records its token usage from the Claude API response: `input_tokens`, `output_tokens`,
  `cache_read_tokens`, `cache_write_tokens`, `model_id`, and timestamp. A stopped turn
  records the tokens consumed up to the cancellation point.
- **G2 — Convert tokens to credits and store in `user-service`.** `user-service` owns the
  `model_pricing` table (internal USD per-token rates) and the credit conversion rate
  (`usd_to_credits`). It calculates `credits_used` at write time from the raw token counts
  and stores both raw tokens and credits in the `turn_cost` table. USD is stored internally
  for accounting but is never surfaced to users.
- **G3 — Aggregate credits per session.** Each session maintains a running
  `total_credits_used` updated on every new `turn_cost` insert. The aggregate is maintained
  incrementally by `user-service`, not recomputed on read.
- **G4 — Display credits in the chat UI.** Each agent message card shows its cost in
  credits (`4 credits`). The session / thread header shows the running session total
  (`Session: 25 credits`). Cost is always visible but secondary — small, non-prominent.
- **G5 — Expose cost query API via `workflow-bff`, backed by `user-service`.** `workflow-bff`
  exposes endpoints to query per-turn credits and session-level totals; it proxies to
  `user-service` for storage and retrieval. The API is designed to generalize beyond chat:
  any cost producer (agent runtime task, future tool runs) can submit a cost event and
  appear in the same query surface without workflow-bff changes.
- **G6 — Daily and weekly credit quota per user.** `user-service` tracks each user's
  daily and weekly credit consumption. Each quota refreshes on its own schedule (daily
  at midnight UTC; weekly on Monday midnight UTC). The cap is a fixed system-wide constant
  for now (`DAILY_CREDIT_QUOTA`, `WEEKLY_CREDIT_QUOTA`). The quota surface is exposed via
  the cost query API so the UI can display remaining allowance.
- **G7 — Immutable cost history ledger.** `turn_cost` is an append-only event log — one row
  per agent turn, never mutated after insert. This makes it the authoritative record for
  future cost analysis: filter by `source_type` to see "Hermes agent chat" vs. "agent
  runtime task" spend; join on `task_id` to see per-task runtime costs; group by `user_id`
  and date for usage reports. The schema carries a `source_type` discriminator
  (`chat_turn` | `task_run` | future values) and a nullable `task_id` so runtime wiring is
  additive — no migration needed.

## Non-goals

- **NG1 — No billing, caps, or enforcement.** Spend caps, auto-pause, credit deduction, and
  tier enforcement are M4's core deliverables and are out of scope here. Quota is tracked
  and surfaced; it is not enforced in this feature.
- **NG2 — No USD display to users.** USD is an internal accounting unit only; it must not
  appear anywhere in the UI. Users see credits exclusively.
- **NG3 — No BYO key or model-gateway managed mode.** Per-key or per-org cost allocation
  and gateway-managed API routing are separate enabling track concerns.
- **NG4 — No metering of human actions.** Only LLM API calls generate cost records.
- **NG5 — No retroactive backfill.** Cost records start from the deploy date.
- **NG6 — No agent-runtime wiring in this feature.** The schema supports it (`source_type:
  task_run`), but the runtime pipeline is a follow-on feature.
- **NG7 — No cross-session aggregate dashboard or invoice download.** Per-workspace cost
  dashboards and invoice generation are M4 proper.
- **NG8 — No billing-plan-driven quota caps.** The quota cap is a fixed system constant for
  now; billing plan parameterization is M4 proper.

## User Flows

### Watching a turn cost appear

1. A user sends `@agent draft the spec from what we agreed`.
2. The agent generates and completes the turn.
3. The agent message card appears with a small credit badge: *4 credits*.
4. The session header updates from *Session: 21 credits* to *Session: 25 credits*.
5. The quota indicator in the header refreshes: *Daily: 9,975 / 10,000 credits remaining*.

### Stopping a turn and seeing the partial cost

1. The user clicks **Stop** mid-generation.
2. The partial response is marked *— stopped by user*.
3. The credit badge shows the tokens consumed up to the stop: *1 credit*.
4. The session total and quota remaining both update.

### Checking remaining quota

1. At any time the user can see remaining daily and weekly credits in the session header or
   a profile panel.
2. The quota resets automatically — daily at midnight UTC, weekly on Monday — with no user
   action required.

### Future: billing dashboard consumes the API

M4's billing dashboard will call `GET /users/:id/cost` (via `workflow-bff` → `user-service`)
to produce per-workspace, per-session cost breakdowns. The API shape delivered here is
what M4 consumes — no rework needed.

## Scope

### In scope

**Cost capture (hermes-agent)**
- After every agent turn completion or stop, extract the `usage` block from the Claude API
  response and emit a cost event to `workflow-bff`.
- Event payload: `session_id`, `turn_id`, `user_id`, `model_id`, `input_tokens`,
  `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `stopped` (bool), `timestamp`.
- Stopped turns emit the event with `stopped: true` and the token counts returned up to
  cancellation.

**Cost storage, pricing, and quota (user-service)**
- `model_pricing` table: internal USD per-token rates per model, seeded with current
  Anthropic pricing for Haiku 4.5, Sonnet 4.6, Opus 4.8, Fable 5.
- `credit_rate` config: a single system-wide constant `usd_to_credits` (e.g. 10,000
  credits per USD). Stored as a config row, not hardcoded.
- `turn_cost` table: stores raw token counts, `cost_usd` (internal), and `credits_used`
  (user-facing) per turn. Includes `source_type` and nullable `task_id` for runtime
  extension.
- `user_usage_quota` table: per-user daily and weekly credit usage and cap, with
  `daily_reset_at` and `weekly_reset_at` timestamps. Incremented on every `turn_cost`
  insert; reset on schedule.
- A `POST /internal/turn-costs` endpoint on `user-service` to receive cost events from
  `workflow-bff`. Calculates credits, writes `turn_cost`, increments quota.
- A `GET /internal/users/:id/cost` endpoint returning per-turn credits, session totals,
  and quota state.

**Cost API (workflow-bff)**
- `POST /sessions/:id/turn-costs` — receive cost event from `hermes-agent`, forward to
  `user-service`. Does not write cost data itself.
- `GET /sessions/:id/cost` — proxy to `user-service`, return `{ session_credits,
  turn_count, quota: { daily_used, daily_limit, weekly_used, weekly_limit,
  daily_reset_at, weekly_reset_at }, turns: [{turn_id, credits_used, model_id,
  tokens, stopped}] }`.
- Both endpoints require workspace-scoped auth (existing session auth).

**Cost display (digital-factory-ui)**
- Agent message card: small credit badge (`4 credits`) below message content. Stopped
  messages show the badge alongside the stopped indicator.
- Session / thread header: running session total (`Session: 25 credits`) and quota
  indicator (`Daily: 9,975 / 10,000`). Updates reactively as new turn costs arrive via
  the existing SSE stream or message-list refresh.
- No USD values appear anywhere in the UI.

### Out of scope (tracked separately)

- Agent-runtime (task-execution) cost wiring — follow-on, same schema, different producer.
- Quota enforcement (auto-pause, hard cap) — M4 proper.
- Billing-plan-driven quota caps — M4 proper.
- Cross-session cost dashboard, cost export, invoice download — M4 proper.
- BYO key / gateway-managed cost allocation.

## Data Model

All cost and quota tables live in **`user-service`**.

```
model_pricing                        (user-service)
├── model_id           TEXT PK
├── input_cost_per_mtok      NUMERIC  -- USD per million input tokens (internal)
├── output_cost_per_mtok     NUMERIC
├── cache_read_cost_per_mtok NUMERIC
├── cache_write_cost_per_mtok NUMERIC
├── effective_from     TIMESTAMPTZ
└── effective_to       TIMESTAMPTZ    -- null = current

credit_config                        (user-service — single row)
├── id                 INTEGER PK DEFAULT 1
└── usd_to_credits     NUMERIC        -- e.g. 10000 (credits per USD)

turn_cost                            (user-service — append-only cost history ledger)
├── id                 UUID PK
├── user_id            UUID FK → users
├── session_id         UUID           -- FK reference only; not a FK constraint (cross-service)
├── turn_id            UUID           -- FK reference only
├── source_type        TEXT           -- 'chat_turn' | 'task_run'  (analysis discriminator)
├── source_label       TEXT           -- human-readable: 'Hermes Agent' | 'Agent Runtime' | …
├── task_id            UUID nullable  -- populated by runtime wiring later; enables per-task cost
├── model_id           TEXT FK → model_pricing
├── input_tokens       INTEGER
├── output_tokens      INTEGER
├── cache_read_tokens  INTEGER
├── cache_write_tokens INTEGER
├── cost_usd           NUMERIC(12,8)  -- internal accounting only, never exposed to UI
├── credits_used       NUMERIC(12,2)  -- user-facing unit
├── stopped            BOOLEAN DEFAULT false
└── created_at         TIMESTAMPTZ DEFAULT now()
-- Index on (user_id, created_at) for per-user history queries
-- Index on (source_type, created_at) for cost-by-source analysis

user_usage_quota                     (user-service)
├── id                 UUID PK
├── user_id            UUID FK → users UNIQUE
├── daily_credits_used NUMERIC(12,2) DEFAULT 0
├── daily_credits_cap  NUMERIC(12,2)  -- system constant for now (DAILY_CREDIT_QUOTA)
├── daily_reset_at     TIMESTAMPTZ    -- next midnight UTC
├── weekly_credits_used NUMERIC(12,2) DEFAULT 0
├── weekly_credits_cap  NUMERIC(12,2) -- system constant for now (WEEKLY_CREDIT_QUOTA)
├── weekly_reset_at    TIMESTAMPTZ    -- next Monday midnight UTC
└── updated_at         TIMESTAMPTZ DEFAULT now()
```

`session.total_credits_used` is derived from `SUM(turn_cost.credits_used)` on read (or
cached by `user-service` in a `session_cost_cache` table if query performance requires it —
technical design decision).

## Open Questions

None — all scoping decisions are locked.

## Success Criteria

- Every completed or stopped agent chat turn produces a `turn_cost` record in `user-service`
  with correct token counts, a non-zero `credits_used`, and a `cost_usd` (internal only).
- The agent message card shows `credits_used` immediately after the turn completes (or stops).
  No USD values appear anywhere in the UI.
- The session header shows the running session total in credits and updates after each turn.
- The quota indicator shows correct `daily_credits_used`, `daily_credits_cap`,
  `weekly_credits_used`, and `weekly_credits_cap` for the authenticated user.
- Daily quota resets at midnight UTC; weekly quota resets Monday midnight UTC.
- The cost query API returns credits (not USD) for all per-turn and session-level values.
- `workflow-bff` does not own any cost or quota tables — all writes and reads go through
  `user-service`.
- A `model_pricing` seed migration in `user-service` contains current Anthropic pricing
  for Haiku 4.5, Sonnet 4.6, Opus 4.8, and Fable 5.
- `turn_cost.source_type`, `turn_cost.source_label`, and `turn_cost.task_id` are present,
  confirming the cost history ledger is queryable by source and the runtime extension path
  is ready. `source_label` reads `'Hermes Agent'` for all chat-turn records in this feature.
- No row in `turn_cost` is ever mutated after insert — the table is append-only.
- Lint, type-check, and the full test suites of all touched repos pass before any PR.

## References

- Roadmap: `docs/roadmap-milestone.md` → **M4 — Meter & Monetize** (credits, per-model
  conversion table, tier ladder, spend caps, cost dashboard). This feature delivers the
  raw credit signal and quota foundation M4's billing engine will build on.
- Stop-agent-chat: `docs/features/m3-stop-agent-chat/` — stopped turns must also emit a
  cost event with the tokens consumed up to cancellation.
- Agent chat v4: `docs/features/m3-agent-chat-v4/` — the real-time thread surface where
  per-turn credit badges and quota indicators will be displayed.
- Claude usage limits (design reference): daily and weekly refresh quota pattern.
- Touched repos: `hermes-agent` (cost event emission), `user-service` (model pricing,
  turn_cost, quota tables + internal API), `workflow-bff` (cost event routing + cost
  query proxy), `digital-factory-ui` (credit badges + quota indicator).
