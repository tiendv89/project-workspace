# Product Specification

## Feature
- Feature ID: `m4-agent-cost`
- Title: Agent Cost Tracking — Credits, Billing Plans, and Quota

## Background

The M3 agent-chat line now delivers a full team-chat surface with triggered agent dispatch,
real-time delivery, and a stop mechanism. Every agent turn calls the Claude API from the
`hermes-agent` process and consumes tokens — input tokens, output tokens, and cache tokens.
Today that usage is **invisible**: there is no record of what a turn costs, no per-session
accumulation, and no cost surface in the UI.

M4 is scoped as "Meter & Monetize" — metering ledger, credits, tiers, spend caps, and per-
workspace cost dashboard. The roadmap is explicit: *"plan → entitlement mapping is
config/data; enforcement is deterministic code, never an LLM judgement."* This feature
delivers the foundation for that: cost capture, a credit-based quota system, and
**admin-managed billing plans** that drive the quota caps for individual users and orgs.

This feature deliberately excludes self-serve payment, payment processing, and billing
infrastructure. Plans are created and assigned by an admin via the admin panel —
not purchased by users. M4's full billing engine (Stripe, wallet, auto-pause, invoicing)
is a follow-on; this feature builds the plan data model and enforcement gate that billing
will slot into without rework.

This feature also designs the data model so the agent runtime (task-execution workers in
the workflow orchestrator) can emit cost events with no schema migration required.

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
the moment any cap is enforced.

### All users share the same hardcoded cap — no differentiation

Without a billing plan layer, every user gets the same quota regardless of their role,
engagement type, or commercial arrangement. There is no way to give a paying client a
higher allowance, put an inactive account on a tighter limit, or set a workspace-level
baseline that all members inherit. Any future commercial differentiation (Free / Pro / Team
/ Enterprise tiers) needs this plan-data-model to already exist.

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
  (`Session: 25 credits`) and the user's remaining daily quota. Cost is always visible but
  secondary — small, non-prominent.
- **G5 — Expose cost query API via `workflow-bff`, backed by `user-service`.** `workflow-bff`
  exposes endpoints to query per-turn credits and session-level totals; it proxies to
  `user-service` for storage and retrieval. The API is designed to generalize beyond chat:
  any cost producer (agent runtime task, future tool runs) can submit a cost event and
  appear in the same query surface without `workflow-bff` changes.
- **G6 — Daily and weekly credit quota, driven by billing plan.** `user-service` tracks each
  user's daily and weekly credit consumption. The daily and weekly caps come from the user's
  **effective billing plan** (resolved from individual plan → org plan → system default,
  in that priority order). Each quota refreshes on schedule (daily at midnight UTC; weekly
  on Monday midnight UTC). The quota surface is exposed via the cost query API.
- **G7 — Immutable cost history ledger.** `turn_cost` is an append-only event log — one row
  per agent turn, never mutated after insert. This makes it the authoritative record for
  future cost analysis: filter by `source_type` to see Hermes agent chat vs. agent runtime
  spend; join on `task_id` to see per-task costs; group by `user_id` and date for usage
  reports. The schema carries a `source_type` discriminator (`chat_turn` | `task_run` |
  future values) and a nullable `task_id` so runtime wiring is additive — no migration.
- **G8 — Quota guard in `hermes-agent`.** Before invoking the Claude API for a new turn,
  `hermes-agent` checks the user's current quota state via `user-service`. If either the
  daily or weekly cap is reached, the turn is **rejected before any tokens are consumed**:
  the agent posts a system message to the thread with the exhausted quota type and reset
  time, and the composer remains enabled.
- **G9 — Admin-managed billing plans (individual and org).** An admin can create and edit
  billing plans (name, daily credit cap, weekly credit cap). Plans can be assigned to an
  **individual user** or to an **org** (applies to all org members as a baseline). The
  resolution order is: individual plan → org plan → system default. No self-serve payment
  or plan-purchase UI exists; all plan assignment is admin-only, via the admin panel.

## Non-goals

- **NG1 — No self-serve payment or payment processing.** Users cannot purchase plans or
  credits through the UI. All plan assignment is admin-only. Stripe, wallets, invoicing,
  and credit purchase flows are M4's full billing engine, explicitly out of scope here.
- **NG2 — No USD display to users.** USD is an internal accounting unit only; it must not
  appear anywhere in the UI. Users see credits exclusively.
- **NG3 — No auto-pause or spend-cap enforcement beyond the daily/weekly quota guard.**
  Automatic subscription downgrade, auto-pause at a rolling spend threshold, and prorated
  billing are M4 proper.
- **NG4 — No BYO key or model-gateway managed mode.** Per-key or per-org cost allocation
  and gateway-managed API routing are separate enabling track concerns.
- **NG5 — No metering of human actions.** Only LLM API calls generate cost records.
- **NG6 — No retroactive backfill.** Cost records start from the deploy date.
- **NG7 — No agent-runtime wiring in this feature.** The schema supports it (`source_type:
  task_run`), but the runtime pipeline is a follow-on feature.
- **NG8 — No cross-session aggregate dashboard or invoice download.** Per-workspace cost
  dashboards and invoice generation are M4 proper.

## User Flows

### Watching a turn cost appear

1. A user sends `@agent draft the spec from what we agreed`.
2. The agent generates and completes the turn.
3. The agent message card appears with a small credit badge: *4 credits*.
4. The session header updates from *Session: 21 credits* to *Session: 25 credits*.
5. The quota indicator refreshes: *Daily: 9,975 / 10,000 credits remaining*.

### Stopping a turn and seeing the partial cost

1. The user clicks **Stop** mid-generation.
2. The partial response is marked *— stopped by user*.
3. The credit badge shows the tokens consumed up to the stop: *1 credit*.
4. The session total and quota remaining both update.

### Hitting the daily quota limit

1. A user sends `@agent` when their daily quota is already exhausted.
2. `hermes-agent` calls the quota check endpoint **before** calling the Claude API.
3. The check returns `{ allowed: false, reason: 'daily_exceeded', resets_at: <timestamp> }`.
4. No Claude API call is made; zero tokens are consumed.
5. The agent posts a system message:
   *"You've reached your daily credit limit (10,000). Your quota resets at midnight UTC
   (in 3h 42m)."*
6. The composer stays enabled — the user can try again after the reset.
7. The same flow applies for weekly exhaustion with an appropriate reset time.

### Admin creates a billing plan

1. An admin opens the **admin app** → **Plans** page.
2. They click **New Plan**, enter a name (e.g. `Pro`), a daily cap (50,000 credits), and a
   weekly cap (200,000 credits), then save.
3. The plan appears in the plan list immediately and is available to assign — no redeploy.

### Admin assigns a plan to an individual user

1. In the admin app → **Users**, the admin finds a user.
2. Under **Billing Plan**, they select `Pro` from the plan dropdown and save.
3. On the next quota check for that user, `user-service` resolves the effective plan as
   `Pro` (individual plan takes precedence) and applies its caps.

### Admin assigns a plan to an org

1. In the admin app → **Orgs**, the admin opens an org and selects a plan (e.g. `Team`).
2. All members of that org without an individual plan assigned now inherit `Team` caps.
   Members with an individual plan are unaffected.

### Effective plan resolution (visible in admin)

The admin app shows each user's **effective plan** and its source:
- *Pro (individual)* — user has an individual plan assigned
- *Team (org)* — user inherits from their org's plan
- *Free (default)* — neither individual nor org plan is set; seeded default applies

### Future: billing dashboard consumes the API

M4's billing dashboard will call the cost query API to produce per-workspace, per-session
cost breakdowns. The plan model delivered here is what M4 connects Stripe to — no rework.

## Scope

### In scope

**Cost capture and quota guard (hermes-agent)**
- **Pre-turn quota check (G8):** before invoking the Claude API, call the quota check
  endpoint via `workflow-bff`. If `allowed: false` → post system message, return without
  calling the API. Zero tokens consumed on a blocked turn.
- After every turn completion or stop, extract the `usage` block and emit a cost event to
  `workflow-bff`.
- Event payload: `session_id`, `turn_id`, `user_id`, `model_id`, `input_tokens`,
  `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `stopped` (bool), `timestamp`.
- Stopped turns emit with `stopped: true` and the token counts up to cancellation.

**Billing plans, cost storage, pricing, and quota (user-service)**

*Plan management:*
- `billing_plan` table: named plans with `daily_credits_cap` and `weekly_credits_cap`.
  All caps are **admin-configurable data** — they live in the DB and can be changed via
  the admin panel at any time without a code deploy or environment variable change.
  A `free` plan is seeded in the initial migration with sensible defaults; the admin may
  edit those defaults after deploy. No plan property is hardcoded or driven by env vars.
- `user_plan_assignment` table: assigns a plan to an individual user (admin-only write).
- `org_plan_assignment` table: assigns a plan to an org (admin-only write).
- Plan resolution function: given a `user_id`, returns the effective plan following the
  priority order — individual → org → `free` default. Used by quota check and quota
  increment.

*Internal API endpoints:*
- `GET /internal/users/:id/quota/check` — resolves effective plan, applies lazy reset if
  needed, returns `{ allowed, reason?, resets_at?, plan_name, daily_cap, weekly_cap }`.
- `POST /internal/turn-costs` — calculates credits, writes `turn_cost`, increments quota.
- `GET /internal/users/:id/cost` — returns per-turn credits, session totals, and quota
  state including plan name and caps.

*Admin API endpoints (new, admin-auth required):*
- `POST /admin/plans` — create a plan.
- `PATCH /admin/plans/:id` — edit a plan's caps or name.
- `GET /admin/plans` — list all plans.
- `POST /admin/users/:id/plan` — assign a plan to a user.
- `DELETE /admin/users/:id/plan` — remove a user's individual plan assignment.
- `POST /admin/orgs/:id/plan` — assign a plan to an org.
- `DELETE /admin/orgs/:id/plan` — remove an org plan assignment.
- `GET /admin/users/:id/effective-plan` — return the user's effective plan and source
  (`individual` | `org` | `default`).

*Tables:*
- `model_pricing`: internal USD rates per model, seeded with current Anthropic pricing.
- `credit_config`: single-row `usd_to_credits` conversion constant.
- `turn_cost`: append-only cost history ledger (see Data Model).
- `user_usage_quota`: per-user usage counters with `plan_id` FK (resolved at quota check;
  updated if the user's plan changes).

**Cost API (workflow-bff)**
- `POST /sessions/:id/turn-costs` — receive cost event from `hermes-agent`, forward to
  `user-service`.
- `GET /sessions/:id/cost` — proxy to `user-service`; returns `{ session_credits,
  turn_count, quota: { daily_used, daily_cap, weekly_used, weekly_cap, plan_name,
  daily_reset_at, weekly_reset_at }, turns: [{turn_id, credits_used, model_id, tokens,
  stopped}] }`.
- `GET /sessions/:id/quota/check` — proxy the pre-turn quota check to `user-service`.
- All endpoints require workspace-scoped auth.

**Admin plan UI (standalone admin app — separate from `digital-factory-ui`)**
- The admin interface is a **separate frontend application**, not a route or panel inside
  `digital-factory-ui`. It is only accessible to users with the admin role and is deployed
  independently.
- **Plans page**: list all plans, create a plan (name, display name, daily cap, weekly cap),
  edit any plan's caps inline. All edits persist to `user-service` immediately — no deploy.
- **Users page**: per-user row showing effective plan + source (`individual` / `org` /
  `default`); click a user to assign or remove an individual plan.
- **Orgs page**: per-org row showing current org plan; assign or remove an org plan.
- Admin app authenticates against the same identity layer as `digital-factory-ui` but
  enforces an admin-role guard on every route.

**Cost display (digital-factory-ui — chat UI)**
- Agent message card: small credit badge (`4 credits`). Stopped messages show the badge
  alongside the stopped indicator.
- Session / thread header: running session total (`Session: 25 credits`) and quota
  indicator (`Daily: 9,975 / 10,000 · Pro plan`). Updates reactively.
- No USD values anywhere in the UI.

### Out of scope (tracked separately)

- Self-serve plan purchase, Stripe, wallets, invoicing, auto-pause — M4 full billing engine.
- Agent-runtime cost wiring — follow-on, same schema, different producer.
- Cross-session aggregate cost dashboard — M4 proper.
- BYO key / gateway-managed cost allocation.

## Data Model

All tables live in **`user-service`**.

```
billing_plan                         (user-service)
├── id                 UUID PK
├── name               TEXT UNIQUE    -- e.g. 'free', 'pro', 'team', 'enterprise'
├── display_name       TEXT
├── daily_credits_cap  NUMERIC(12,2)  -- admin-editable; no env-var backing
├── weekly_credits_cap NUMERIC(12,2)  -- admin-editable; no env-var backing
├── created_at         TIMESTAMPTZ DEFAULT now()
└── updated_at         TIMESTAMPTZ DEFAULT now()

user_plan_assignment                 (user-service — admin-only writes)
├── id                 UUID PK
├── user_id            UUID FK → users UNIQUE
├── plan_id            UUID FK → billing_plan
├── assigned_by        UUID FK → users  -- admin user
├── assigned_at        TIMESTAMPTZ DEFAULT now()
└── expires_at         TIMESTAMPTZ nullable   -- null = no expiry

org_plan_assignment                  (user-service — admin-only writes)
├── id                 UUID PK
├── org_id             UUID UNIQUE           -- FK reference (cross-service)
├── plan_id            UUID FK → billing_plan
├── assigned_by        UUID FK → users
├── assigned_at        TIMESTAMPTZ DEFAULT now()
└── expires_at         TIMESTAMPTZ nullable

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
└── usd_to_credits     NUMERIC        -- e.g. 10000 credits per USD

turn_cost                            (user-service — append-only cost history ledger)
├── id                 UUID PK
├── user_id            UUID FK → users
├── session_id         UUID           -- cross-service reference (no FK constraint)
├── turn_id            UUID           -- cross-service reference
├── source_type        TEXT           -- 'chat_turn' | 'task_run'
├── source_label       TEXT           -- 'Hermes Agent' | 'Agent Runtime' | …
├── task_id            UUID nullable  -- populated by runtime wiring later
├── model_id           TEXT FK → model_pricing
├── input_tokens       INTEGER
├── output_tokens      INTEGER
├── cache_read_tokens  INTEGER
├── cache_write_tokens INTEGER
├── cost_usd           NUMERIC(12,8)  -- internal only, never exposed to UI
├── credits_used       NUMERIC(12,2)  -- user-facing unit
├── stopped            BOOLEAN DEFAULT false
└── created_at         TIMESTAMPTZ DEFAULT now()
-- Index: (user_id, created_at)
-- Index: (source_type, created_at)

user_usage_quota                     (user-service — one row per user, upserted)
├── id                 UUID PK
├── user_id            UUID FK → users UNIQUE
├── plan_id            UUID FK → billing_plan   -- effective plan at last check
├── daily_credits_used NUMERIC(12,2) DEFAULT 0
├── daily_reset_at     TIMESTAMPTZ    -- next midnight UTC
├── weekly_credits_used NUMERIC(12,2) DEFAULT 0
├── weekly_reset_at    TIMESTAMPTZ    -- next Monday midnight UTC
└── updated_at         TIMESTAMPTZ DEFAULT now()
-- Caps are read from billing_plan at check time, not stored here —
-- so a plan cap change takes effect on the next check without a migration.
```

**Plan resolution algorithm** (used by quota check and any cap read):
1. Check `user_plan_assignment` for the `user_id` — if found and not expired, use that plan.
2. Else look up the user's `org_id`, check `org_plan_assignment` — if found and not expired,
   use that plan.
3. Else use the `billing_plan` row where `name = 'free'` (the seeded system default).

`session.total_credits_used` is derived from `SUM(turn_cost.credits_used)` on read, or
cached by `user-service` if query performance requires it (technical design decision).

## Open Questions

None — all scoping decisions are locked.

## Success Criteria

- When a user's daily or weekly quota is exhausted, `hermes-agent` rejects the turn before
  calling the Claude API; a system message appears in the thread with the quota type, cap,
  and reset time. Zero tokens are consumed on a rejected turn.
- Every completed or stopped agent chat turn produces a `turn_cost` record with correct
  token counts, `credits_used`, and `cost_usd` (internal only). `source_label` is
  `'Hermes Agent'` for all chat-turn records.
- `user_usage_quota` counters reflect the correct cumulative credits used; daily counter
  resets at midnight UTC and weekly counter resets Monday midnight UTC.
- The quota caps applied at check time come from the user's effective billing plan
  (individual → org → free default), not a hardcoded constant.
- An admin can create a plan, assign it to a user, assign it to an org, and view each
  user's effective plan and source in the admin panel.
- A user assigned an individual plan sees that plan's caps in the quota indicator.
- An org member without an individual plan sees the org plan's caps; a member with an
  individual plan is unaffected by the org plan.
- The agent message card shows `credits_used` in the UI. No USD values appear anywhere.
- The session header shows the session credit total, remaining daily quota, and plan name.
- `workflow-bff` owns no cost or quota tables — all writes and reads go through
  `user-service`.
- `turn_cost` rows are never mutated after insert (append-only verified in tests).
- `turn_cost.source_type`, `source_label`, and `task_id` are present, confirming the cost
  history ledger is ready for runtime extension.
- A `model_pricing` seed and a `billing_plan` seed (at minimum: `free` with reasonable
  default caps) are present in `user-service` migrations. The `free` plan's caps are
  editable by an admin after deploy — no redeploy or env-var change required.
- Lint, type-check, and the full test suites of all touched repos pass before any PR.

## References

- Roadmap: `docs/roadmap-milestone.md` → **M4 — Meter & Monetize** — "the full tier ladder
  (Free / Pro / Max / Team / Enterprise)"; "plan → entitlement mapping is config/data;
  enforcement is deterministic code." This feature delivers the plan data model and
  enforcement gate M4's billing engine will slot into.
- Stop-agent-chat: `docs/features/m3-stop-agent-chat/` — stopped turns must emit a cost
  event with tokens consumed up to cancellation.
- Agent chat v4: `docs/features/m3-agent-chat-v4/` — the real-time thread surface where
  per-turn credit badges and the quota indicator are displayed.
- Admin panel: `docs/features/m1-admin-panel/` — context on the existing admin identity
  model and auth guard the new standalone admin app will reuse.
- Claude usage limits (design reference): daily and weekly refresh quota pattern.
- Touched repos: `hermes-agent` (cost event emission + quota guard), `user-service` (plan
  tables, pricing, quota, admin + internal APIs), `workflow-bff` (cost event routing + cost
  query proxy), `digital-factory-ui` (credit badges + quota indicator in chat UI),
  and a **new standalone admin app repo** (billing plan management UI — repo to be
  registered in `workspace.yaml` by the tech lead during technical design).
