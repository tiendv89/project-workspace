# Platform Roadmap — Discussion Doc

> Status: **draft for discussion**, not an approved plan.
> This doc captures direction and open questions across several initiatives so we
> can argue about sequencing and shape *before* writing per-feature specs. It is
> deliberately opinionated to give us something to push against.

It sits under [`product-thesis.md`](./product-thesis.md) — re-read that first. Every
item here is checked against the thesis's four layers (**Rules are code, Skills are
tools, Agents are workers, Humans are gates**) and its rule that **surfaces are
agent-native by default** (one set of rails for human and agent clients).

Several of these initiatives also resolve gaps the thesis explicitly left open:
pricing model, hosting model, vendor lock-in, and the shape of the copilot surface.
That makes them strategic, not just features.

---

## The one big picture

The six items are not independent features — they stack into a platform. Read
top-to-bottom as a dependency stack:

```
                ┌─────────────────────────────────────────────┐
   SURFACE      │  Collaborative chat surface (item 5):           │   ← how humans & agents
                │  chat + tagging + stream; spec→discuss→trigger   │     drive the system
                └───────────────┬───────────────────────────────┘
                                │ acts through skills/MCP (never bypasses gates)
   ENTITLEMENTS ┌───────────────▼───────────────────────────────┐
   & ACCESS     │  Governance × delivery roles  ×  Billing plan   │   ← who admins ×
                │  entitlements (what the org may do)             │     who holds gates × commercial
                └───────────────┬───────────────────────────────┘
                                │ enforced as deterministic rules (code, not LLM)
   METERING     ┌───────────────▼───────────────────────────────┐
                │  Usage metering: tokens, agent-runs, workspaces │   ← the number billing
                │  (multi-tenant, workspace_id-scoped, from day 1) │     and quotas read from
                └───────────────┬───────────────────────────────┘
                                │
   IDENTITY     ┌───────────────▼───────────────────────────────┐
                │  Authentication: users, orgs, personal spaces   │   ← the foundation
                │  (workflow-authentication, v1 next up)           │     everything hangs off
                └───────────────┬───────────────────────────────┘
                                │ access decided by platform, not GitHub
   STORAGE      ┌───────────────▼───────────────────────────────┐
   & VCS        │  Workspace storage: GitHub today → DB tomorrow   │   ← swappable backend,
                │  VCS binding: org + multi-repo + bot (item 6)    │     invisible to layers above
                │  (adapter contract; identity unchanged either way)│
                └─────────────────────────────────────────────────┘
```

The ordering principle: **you cannot meter what has no owner, cannot bill what you
don't meter, cannot gate by plan what has no permission model, and cannot build a
trustworthy collaboration surface without all of the above.** Identity is the floor.

---

## 1. Workflow authentication (foundation → enterprise)

> Spec status: **not yet written.** We are discussing the design here first; the
> v1 `product-spec.md` will be generated from this section once the open decisions
> below are settled. The **phased roadmap** at the end of this item lays out where
> auth goes beyond v1 — this is a full arc, not a v1-only scope.

**The problem:** there is no authentication today — anyone with the dashboard URL
can act, there is no concept of a user or account, and workspace identity + GitHub
PATs live in browser `localStorage`. This blocks both private individual use and
any company (SaaS) engagement.

### Decisions already aligned

- **Unified account model.** One user identity. Every user gets a **personal
  account** (an org-of-one) at signup and can additionally create or join
  **organization accounts** (companies). Personal and org contexts coexist; the
  user switches between them.
- **Both individuals and orgs own multiple workspaces.** A workspace belongs to
  exactly one account; the account is the tenancy boundary (`workspace_id`).
- **Sign-in methods (v1):** email + password (verify + reset) and social OAuth —
  **Google** and **GitHub**. Enterprise **SSO/SAML** is *designed-for, delivered
  later*.
- **Permissions:** preset roles `owner` / `admin` / `member` / `viewer`, plus
  **per-workspace scoping** for member/viewer. Custom roles are deferred.
- **No billing in v1** (see item 2); the model leaves room for it.
- **The platform — not GitHub — is the access authority.** Membership/role/scope
  decide who can see or act on a workspace, never GitHub repo permissions. This is
  what lets the storage backend swap later (item 4).

### Consequence to call out

Auth introduces the **first real backend + persistent datastore** for the product.
The dashboard's v1 was deliberately backend-less (GitHub Contents API straight from
the browser, PAT in `localStorage`). Accounts, sessions, memberships, and roles
cannot live in `localStorage` — so this feature is also where the dashboard grows a
server side. That is a bigger architectural step than "add a login screen," and it
shapes items 4–6.

### Open decisions to settle before writing the spec

1. **Build vs. buy identity** — a managed auth provider (Clerk / WorkOS / Auth0 /
   Supabase Auth / Better Auth) vs. self-hosted auth in `workflow-backend`. Big
   lever: it touches the thesis's open **hosting** (SaaS vs customer-hosted) and
   **vendor-lock-in** questions, and data-residency for Enterprise.
2. **GitHub/GitLab repo-access model** — *leaning resolved by item 6:* a VCS **App**
   (per-install, fine-grained, revocable tokens) that the org grants, with a platform
   **bot identity** for commits — not a user PAT. Confirm the App route and how it
   relates to the deferred credential vault.
3. **How today's GitHub-repo workspaces map onto accounts** — onboarding flow when a
   workspace *is* a GitHub repo, and whether existing `localStorage` workspaces are
   migrated or simply re-connected under the new account (currently leaning:
   re-connect, no auto-migration).
4. **Session model** — managed-provider sessions vs. own JWT/server sessions; token
   lifetime and revocation. (Likely falls out of decision 1.)

### Phased roadmap (v1 → enterprise)

The "Decisions already aligned" above are **Phase 1**. The arc beyond it:

**Phase 1 — Foundation (v1, next up)**
- Email + password (verify, reset); Google + GitHub OAuth; account linking.
- Personal accounts (org-of-one) + organization accounts; context switching.
- Governance roles (owner/admin/member/viewer) + per-workspace scoping.
- Delivery roles (PO / Architect / Reviewer / QC) assigned per workspace (item 3).
- Sessions, sign-out; platform-as-access-authority (storage-independent).

**Phase 2 — Account security & self-serve trust**
- **MFA / 2FA** — TOTP first, then **passkeys / WebAuthn** (phishing-resistant; my
  recommended modern default).
- **Session & device management** — view active sessions, revoke a device, "sign out
  everywhere."
- **Step-up auth** — re-prompt for sensitive actions (billing, role changes, granting
  the bot, rotating keys) even within a live session.
- **Magic-link / passwordless** sign-in.
- Account **recovery** flows (lost MFA/device).
- Basic org **audit log** (security events) — feeds the unified event backbone.

**Phase 3 — Enterprise identity**
- **SSO** via SAML **and** OIDC (Okta, Entra, Google Workspace).
- **SCIM provisioning** — auto user de/provisioning + group→role mapping from the
  IdP. Almost always required *alongside* SAML; easy to forget.
- **Verified domains / auto-join** — anyone with `@company.com` joins the org (kills
  invite friction at scale); optional domain-capture.
- **Custom roles + mandatory 4-eyes** — fine-grained permissions and segregation-of-
  duties on spec/design gates (the deferred levers from items 2–3).
- **Session/security policies** — IP allowlists, max session length, forced MFA.
- **Audit export / SIEM streaming** (Splunk, Datadog) + long retention.
- **Data residency / region pinning** (ties to the hosting discussion).

**Phase 4 — Machine & delegated identity**
- **Service accounts + scoped API tokens** — programmatic and (per the agent-native
  thesis) **MCP** access governed by the same entitlements service. Natural pairing
  with the bot identity (item 6).
- **Consented, audited support impersonation** — so we can help a customer in-context
  without sharing credentials.
- **Ownership / org transfer** — hand off `owner` when a founder leaves.
- **Just-in-time elevated access** — temporary role grants with an approval step.
- *(Maybe)* **personal → organization conversion** — upgrade a personal account into
  a company in place (deliberately out of v1 scope; revisit if demand appears).

> **My picks if I had to prioritize beyond v1:** passkeys + session management
> (Phase 2) for credibility, then **SCIM alongside SAML** (Phase 3) because
> enterprise deals stall without provisioning, then **service accounts/API tokens**
> (Phase 4) because they're the agent-native thesis made literal.

### Data model (sketch)

All tables carry `workspace_id` where applicable and use `snake_case` per the schema
rules in `overview.md`. Core entities:

| Table | Key fields | Purpose |
|---|---|---|
| `account` | `id`, `type` (`personal`\|`org`), `name`, `owner_user_id` | The tenancy boundary; owns workspaces |
| `user` | `id`, `email` (verified), `name`, `status` | One human identity |
| `auth_identity` | `user_id`, `provider` (`password`\|`google`\|`github`\|…), `provider_uid` | Account-linking; many identities → one user |
| `membership` | `user_id`, `account_id`, `governance_role` (`owner`/`admin`/`member`/`viewer`) | Who belongs to which account + governance role |
| `workspace` | `id`, `account_id`, `storage_backend`, … | Owned by exactly one account |
| `workspace_role` | `user_id`, `workspace_id`, `delivery_roles[]` (`po`/`architect`/`reviewer`/`qc`) | Per-workspace delivery-role assignment (item 3) |
| `invitation` | `account_id`, `email`, `governance_role`, `workspace_scope`, `token`, `status` | Email invite → accept flow |
| `session` | `id`, `user_id`, `expires_at`, `revoked_at` | Sign-in sessions (or delegated to the provider in build-vs-buy) |
| `audit_event` | `account_id`, `actor`, `action`, `at`, `meta` | Security/audit log (Phase 2); feeds the event backbone |

This is the spine other items hang fields off: billing attaches plan/credit state to
`account`; item 3 reads `membership` + `workspace_role`; item 6 attaches VCS bindings
to `workspace`/`account`.

**Thesis fit:** identity is infrastructure under the spine, not a gate the agent
interprets. The new server side must keep the rule that **one set of rails serves
human and agent clients** — auth/permission checks live behind the same skills/MCP
surface, not a separate path.

**Roadmap role:** the foundation. Every other item assumes an account exists.

---

## 2. Billing — Free / Pro / Max / Team / Enterprise (usage-based on agent tokens)

**Core principle: plan tier follows account type** (from item 1). Personal accounts
run on the consumer tiers; organization accounts run on the team/enterprise tiers.
This keeps the model coherent — a solo user plays every delivery role themselves and
uses agents as workers; real PO/architect/reviewer/QC collaboration is an org concern.

| Tier | Account | Audience | Price *(strawman)* |
|---|---|---|---|
| **Free** | Personal | Try / hobby | $0 |
| **Pro** | Personal | Serious solo dev | ~$25/mo |
| **Max** | Personal | Power solo / founder | ~$150/mo |
| **Team** | **Org** | Startup / SMB | ~$35/seat/mo |
| **Enterprise** | **Org** | Company / regulated | Custom |

### 2.1 What each tier includes

| Dimension | Free | Pro | Max | Team | Enterprise |
|---|---|---|---|---|---|
| **Usage (credits)** | Trial credit grant (hard stop) | Included credits + overage | Big credit pool + overage | Per-seat credits, pooled + overage | Volume credit commit / negotiated |
| Models available | Sonnet / Haiku class | + Opus / GPT-5 class | all top models | all top models | all providers (Claude, GPT, Gemini, …) |
| **Model selection** | default (auto) | default (auto) | **custom** | **custom** | **custom + per-stage policy** |
| BYO price (own key) | free | **$10/mo** | **$50/mo** | **$15/seat·mo** | custom |
| Concurrent agents | 1 | 2–3 | 5+ | Scales w/ seats | Configurable |
| Workspaces | 1 | 3–5 | Unlimited | Unlimited | Unlimited |
| Connected repos (item 6) | 1 | a few | more | many | unlimited |
| Seats | 1 | 1 | 1 | Multi (no minimum) | Unlimited |
| Delivery-role collab | self (all) | self | self | **real, per-person** | real + custom |
| Governance roles + scoping | — | — | — | ✅ | ✅ |
| Collaboration surface (chat/tag) | — | solo | solo | ✅ | ✅ |
| Audit log | — | — | — | short retention | long + export |
| SSO/SAML · custom roles | — | — | — | — | ✅ |
| Hosting | SaaS | SaaS | SaaS | SaaS | + customer-hosted / residency |
| Support | Community | Email | Priority | Priority | SLA + dedicated |

**Two funding modes on every tier.** Usage is billed in normalized **credits**
(§2.2): either **managed** (we serve the model — we carry COGS and bake margin into
the credit rate) or **BYO key** (the customer attaches their own provider key — we
don't pay the provider, so they pay a **discounted, credits-free per-tier price** —
Pro $10, Max $50, Team $15/seat). A team that already bought Claude/GPT runs on our
platform at the cheaper BYO price; we skip the third-party bill entirely. Margin logic: **Free is a funded growth cost** (tiny
trial grant, then BYO or upgrade), **Pro/Max** carry credits + margin (consumer
revenue), **Team** is where the collaboration surface earns its keep, and
**Enterprise** monetizes via a volume credit commit / negotiated rate (or BYO at
scale) plus the trust/control features (SSO, custom roles, residency, SLA).

### 2.2 The credit model (decided)

- **Billing unit is the normalized credit**, with a published **per-model conversion
  table**. Raw provider tokens aren't comparable across vendors (different
  tokenizers, wildly different prices), so each model maps to credits per 1K tokens
  reflecting provider cost + our margin. The customer sees one currency regardless of
  which model an agent used; we retune the table as provider prices move.

  **Conversion table** — unit: **1 credit = $0.01**; **markup ~2×** COGS baked in
  (≈50% gross margin on managed tokens before caching). Formula:
  `credits/1K = (COGS $/1M) × 0.2`.

  | Model | COGS in/out ($/1M) | Credits/1K in | Credits/1K out | Price source |
  |---|---|---|---|---|
  | **Claude Opus** 4.5–4.8 | $5 / $25 | 1.0 | 5.0 | ✅ live (claude.com) |
  | **Claude Sonnet** 4.6 | $3 / $15 | 0.6 | 3.0 | ✅ live |
  | **Claude Haiku** 4.5 | $1 / $5 | 0.2 | 1.0 | ✅ live |
  | GPT-5.5 | $5 / $30 | 1.0 | 6.0 | ✅ live (openai) |
  | GPT-5.4 | $2.50 / $15 | 0.5 | 3.0 | ✅ live |
  | **GPT-5.3-Codex** | $1.75 / $14 | 0.35 | 2.8 | ✅ live |
  | GPT-5.4-mini | $0.75 / $4.50 | 0.15 | 0.9 | ✅ live |
  | GPT-5.4-nano | $0.20 / $1.25 | 0.04 | 0.25 | ✅ live |
  | Gemini 2.5 Pro | ~$1.25 / $10 | 0.25 | 2.0 | ⚠️ no source yet |
  | DeepSeek V3 | ~$0.27 / $1.10 | 0.05 | 0.22 | ⚠️ no source yet |

  *A "medium task" (~200K in / 50K out): Opus ≈ 450 credits (~$4.50), GPT-5.5 ≈ 500,
  Sonnet ≈ 270, GPT-5.4 ≈ 250, GPT-5.3-Codex ≈ 210, Haiku ≈ 90, DeepSeek ≈ 21.* Two
  notes worth pricing around: (a) Claude Opus 4.5+ is now **$5/$25** (was $15/$75) —
  only ~1.67× Sonnet; (b) **GPT-5.3-Codex ($1.75/$14)** is a cheap, coding-specialized
  option that undercuts Sonnet on input — a strong **default-model** candidate for
  cost-controlled tiers. Gemini/DeepSeek rows still need a source pull.
- **Margin runs higher than 2× in practice.** Anthropic **cache reads are 0.1× input**
  and the **Batch API is −50%**. Agent workloads re-send large repeated context, so if
  we bill credits at **list** rates but pay **cache/batch-discounted** COGS, realized
  margin on a well-cached workload is ~**2.5–3×**. (Opus 4.7+ uses a new tokenizer that
  can consume up to 35% more tokens — nudges effective Opus cost up slightly.)
- **Two funding modes (per workspace, even per agent):**
  - **Managed** — we call the provider on our account; the run debits credits from
    the allowance/overage. We carry COGS, margin lives in the conversion rate.
  - **BYO provider key** — the customer attaches their own Anthropic/OpenAI/Gemini/…
    key; that run is **metered for visibility but not charged in credits** (their
    provider bills them). BYO is a **discounted per-tier price** (Pro $10, Max $50,
    Team $15/seat) — same tier features, no bundled credits since their key covers
    usage. This is the "already bought Claude → pay us less" path; it offloads COGS
    from us entirely.
- **Included credits + metered overage** on managed usage. Each paid tier bundles a
  monthly credit allowance; beyond it, pay-as-you-go.
- **Org credits are per-seat, pooled into one org bucket** (Team/Enterprise): each
  seat contributes to a shared pool anyone draws from; adding seats grows the pool.
  Optional **per-workspace budget caps** on top.
- **Spend cap → auto-pause** on managed usage: overage bills up to an org-set monthly
  cap; when hit, **agents pause** until next cycle or the cap is raised. The
  runaway-cost **safety valve** — load-bearing because agents spend unattended.
  (BYO usage is bounded by the customer's own provider limits, but we still surface
  it and honor workspace budget caps.)
- **Free is a hard stop**: a tiny trial credit grant on cheap models, 1 workspace,
  1 agent; when exhausted, the user attaches a BYO key or upgrades — no overage on
  Free. Caps our funded exposure and is the faucet/abuse guard.
- **Model selection is a plan entitlement.** Lower tiers (**Free, Pro**) run on a
  **platform-managed default model** — the system picks/auto-routes (cheap model for
  simple steps, stronger model for hard ones) to keep cost predictable and the UX
  simple; the customer doesn't choose. Higher tiers (**Max, Team, Enterprise**) unlock
  **custom model selection** — pick a specific model/provider, and (Enterprise) set a
  **per-stage / per-workspace model policy**. This maps directly onto the existing
  `workspace.yaml → model_policy` (allowed + default per stage); the entitlements
  service (item 3) decides whether a customer may edit that policy or is pinned to the
  default. All models still draw credits via the conversion table regardless of tier.

### 2.3 Metering — the real prerequisite (build first)

You can't bill on tokens you don't measure. A first-class, multi-tenant metering
service — `workspace_id`-scoped from day one — is the actual first deliverable; the
plan/billing surface sits on top of it. Meter the cost drivers we price on:

- **Provider tokens** (input/output, **per model, per provider**) — the raw metric;
  the conversion table (§2.2) turns these into billable **credits**. Record both raw
  tokens and converted credits, and whether the run was **managed or BYO**.
- **Agent runs / agent-minutes**, **concurrent-agent** counts.
- **Workspaces, seats, repos** — countable resources for plan caps.
- Optionally storage, RAG index size, PR/review volume.

Metering emits events; billing, dashboards, quotas, spend-caps, and per-workspace
**cost attribution** all read from the same ledger.

### 2.4 Enforcement stays in the spine

- A **plan → entitlement** map defines token allowance, seat/workspace/concurrency
  caps, and which features unlock. The *mapping* is config/data (so Sales can shape
  Enterprise deals without a deploy); **enforcement is deterministic Go in the rules
  layer** — "is this org over its allowance?", "may this plan add a workspace?" —
  *never* an LLM judgement.
- Integrate a billing provider (Stripe-style) for subscriptions + metered usage +
  invoices; reconcile its state with membership/seat counts.

### 2.5 The model gateway — multi-provider by design

Provider posture is **decided: multi-provider.** We support **Anthropic, OpenAI,
Gemini, DeepSeek, …** behind an internal **model gateway** that every agent run goes
through. The gateway is the heart of the billing model:

- **Routes** a run to the right provider/model (per task, per plan entitlement, or
  by cost/latency policy).
- **Meters** raw tokens per model/provider and **converts to credits** via the §2.2
  table — one normalized currency over many vendors.
- **Switches funding mode per run:** managed (our account → debit credits) or BYO
  (customer key → no credit charge, just the platform fee).
- **Fails over / load-balances** across providers without changing the customer
  contract — they buy "credits," not "Anthropic."

What this gives / costs us:

- **On managed usage we carry COGS + rate-limit/availability risk** — the
  spend-cap/auto-pause valve and per-workspace budgets bound it. Multi-provider
  fail-over also *reduces* single-vendor outage risk.
- **BYO offloads COGS and answers vendor-lock-in** — a team brings its own
  Anthropic/OpenAI/… key, pays the discounted BYO per-tier price, and we never touch
  the provider bill. Zero-COGS revenue; large/regulated customers love it.
- **Customer-hosted / air-gapped Enterprise** is now *easier*, not harder: BYO key +
  a customer-scoped gateway deployment means the customer's keys and provider calls
  stay in their environment. (Still needs a deliberate design — flag for the hosting
  discussion.)

### 2.6 Discounts, coupons & programs (one engine)

Annual discounts, promo codes, OSS/non-profit programs, and Enterprise negotiated
rates are **all the same thing** — a data-driven modifier on what an account pays or
gets. Build **one discount engine**, not per-case logic.

**A discount record has four dimensions:**

| Dimension | Options |
|---|---|
| **Target** | platform fee (margin) · credits (our COGS) · both |
| **Form** | % off · fixed amount off · bonus credits · plan comp (a tier made free) |
| **Scope** | which account, which plan; time-bounded (start/end) or perpetual |
| **Source** | coupon code · program (OSS/non-profit/edu/startup) · manual sales grant · system (annual) |

**How an account qualifies:**
- **Coupon / promo codes** — self-serve (launch, referral, campaigns).
- **Programs** with an `apply → verify → grant → re-verify` lifecycle:
  - **OSS** — verify a public repo + OSI-approved license + activity threshold. We can
    automate this off the **VCS connection (item 6)** — we already see the repos.
  - **Non-profit / education** — verify via a provider (e.g. TechSoup) or manual review.
- **Manual grants** — sales/admin apply a custom rate or comp to an Enterprise account.
- **System** — the annual-billing discount applies automatically.

**The COGS guardrail (the important one).** A discount on the **platform fee** is
cheap — it's our margin. A discount on **credits** is real money out the door
(provider COGS). So generous comps (e.g. *free for OSS*) are structured as a
**fee waiver + BYO-key requirement**, or a **capped credit grant** — never an
unbounded managed-token gift. The spend-cap/auto-pause valve (§2.2) backs this.

**Mechanics:**
- **Enforcement is deterministic** (thesis-consistent): the entitlements service
  computes an account's **effective plan, effective price, and effective credit
  allowance** by applying its active discounts in a defined **precedence/stacking
  order**; discount *definitions* are data, the resolution is code.
- **Lifecycle** — discounts can expire; programs **re-verify periodically** (still
  OSS? still a non-profit?); on lapse, revert to standard pricing with notice.
- **Auditable** — every grant/change lands in the org audit log (item 1 Phase 2).
- **Billing provider** — mirror $-discounts to Stripe coupons/promotion codes, but
  **our discount model stays source of truth** (it also moves credits/entitlements,
  which a payment provider can't express).

### 2.7 Working strawman pricing

> **Strawman — pending the marketing/margin final call.** Structure is firm; the exact
> numbers are commercial calls. Built on the live conversion table (§2.2).

**Shape:** every tier has two prices — **Managed** (we supply tokens) and **BYO**
(you bring your provider key). The **BYO price is the platform fee**; **Managed = BYO
price + a credit bundle** at **$0.010/credit**. **Overage = $0.015/credit** (above the
bundled rate, so committing beats overage). Our COGS ≈ **$0.005/credit** (lower with
caching). Same tier features either way — BYO just drops the bundled credits.

| Tier | Managed | BYO | Included credits/mo (managed) | List COGS | Managed margin* |
|---|---|---|---|---|---|
| Free | $0 | $0 | 500 (cheap default, hard stop) | ~$2.50 | funded cost |
| Pro | $25 | **$10** | 1,500 | ~$7.50 | ~70% |
| Max | $150 | **$50** | 10,000 | ~$50 | ~67% |
| Team | $35/seat | **$15/seat** | 2,000 / seat (pooled) | ~$10/seat | ~71% |
| Enterprise | custom | custom | volume commit | — | negotiated |

\* *Managed margin, list-based. Prompt caching (reads 0.1× input) + Batch (−50%) cut
realized COGS ~30–40%, so true managed margins run higher. **BYO is ~100% gross**
(zero COGS) — the BYO price is almost pure margin.*

**What the bundles buy** (per the §2.2 conversion table): Pro 1,500 cr ≈ 5–6 Sonnet /
7 Codex / 3 Opus tasks; Max 10,000 ≈ 37 Sonnet / 22 Opus; Team 2,000/seat ≈ 7
Sonnet/seat. (Medium task: Sonnet 270, Codex 210, Opus 450, Haiku 90 credits.)

**Positioning notes:**
- **BYO is a cheap, zero-COGS SKU**, not free — Pro $10 / Max $50 / Team $15·seat. A
  team that already pays a provider runs on us at the BYO price; it's almost pure
  margin for us and likely the dominant org SKU. Managed is for those who'd rather not
  manage a key.
- **Caching upside is unbudgeted margin** — every managed margin above is the floor.

**Decided:**
- **Annual billing offers a discount** over monthly (e.g. ~2 months free). Both
  cadences offered.
- **No Team minimum seat count** — an org can run Team with as few as one seat;
  seats scale freely.
- **Team → Enterprise trigger** is feature-driven, not size-driven: a team moves to
  Enterprise when it needs **SSO/SAML, data residency, custom roles, or an SLA** —
  not at some seat threshold.
- **No free trial on paid tiers** — paid plans bill from day one. The **Free tier is
  the trial** (try with the credit grant / BYO key, then upgrade).

**Decided / set:**
- **Conversion table is set** (§2.2) — **Claude and OpenAI rows on live pricing**;
  only Gemini/DeepSeek rows still need a source pull. Markup ~2× / $0.01 per credit,
  with realized margin higher once caching/batch is in play.

**Marketing-owned, not fixed in engineering:**
- **Discount policy values** — OSS/non-profit eligibility rules + percentages, annual
  discount %, stacking precedence — are a **marketing-strategy decision, not a fixed
  constant**. The §2.6 engine is built so these are **configurable data**, set and
  tuned by the business without an engineering deploy. No number to "decide" here; the
  requirement is just that the engine makes them editable.

**Decided:**
- **BYO is a discounted per-tier price, not free:** **Pro $10 · Max $50 · Team
  $15/seat** (Free stays $0; Enterprise custom). BYO buyers get the **same tier
  features** but **no bundled credits** — their own key covers usage, so we bear zero
  COGS and the BYO price is ~pure margin. Managed (Pro $25 / Max $150 / Team $35) adds
  the credit bundle for those who'd rather not manage a key. No paywall/gating
  difference between Managed and BYO beyond the credits themselves.

**Strawman set, pending marketing final call:**
- **Full pricing is in §2.7** — Managed: Pro $25 (1,500 cr) / Max $150 (10,000 cr) /
  Team $35·seat (2,000 cr); BYO: Pro $10 / Max $50 / Team $15·seat; overage $0.015;
  bundle $0.010. Structure is firm; exact numbers are commercial/marketing calls, to
  be confirmed against target margin (with caching upside as headroom).

---

## 3. Permissions — two role dimensions × a plan gate

Permission is **three checks that must all pass**, easy to conflate but distinct:

| Axis | Question it answers | Assigned | Layer |
|---|---|---|---|
| **Governance role** | May you *administer* the org? | once per person, per org | Rules (enforced) |
| **Delivery role** | Which lifecycle *gate / artifact* do you hold? | per person, **per workspace** | Rules (enforced) |
| **Plan entitlement** | Is the *org* allowed to at all? | by billing plan | Rules (enforced) |

An action is allowed only when **all relevant axes agree**: the plan unlocks the
capability, the governance role permits it (if it's an admin action), and the
delivery role grants it (if it's a lifecycle action). One **entitlements service**
answers the single question "can this actor take this action in this context?" for
the chat surface, HTTP API, and MCP tools alike — no divergent paths.

### 3.1 Governance roles (org-level — "can you administer?")

| Role | Can do |
|---|---|
| **owner** | Everything: billing, members, role assignment, workspaces, settings, delete org. **Implicitly holds all delivery roles** (a one-person org is never stuck). |
| **admin** | Members, role assignment, workspaces, settings — **not** billing. Must be **assigned delivery roles** to act on lifecycle gates (separation of duties below owner). |
| **member** | Belongs to the org; acts in the lifecycle **only via assigned delivery roles**; no admin. |
| **viewer** | Read-only across the workspaces they're scoped to. |

### 3.2 Delivery roles (per-workspace — "which gate do you hold?")

Mapped 1:1 onto the lifecycle stages. Thesis pattern: **the human authors intent and
holds the gate; the agent does the work.** A person may hold **multiple** delivery
roles in a workspace; solo Pro/Max users implicitly hold **all** of them.

| Delivery role | Authors / triggers | **Holds the gate** | Agent worker | Existing |
|---|---|---|---|---|
| **Product Owner** | Creates features; `product-spec.md` | **product_spec** approval | PO agent drafts spec | `product_owner` ✓ |
| **Architect / Tech Lead** | `technical-design.md` + task breakdown | **technical_design** + **tasks** approval | tech-lead agent | `tech_lead` ✓ |
| **Reviewer** | Triggers impl agents; reviews their PRs | **PR review → task `done`** | executor + reviewer agent | *(new)* |
| **QC / QA** | Files bug reports; validates | **handoff / quality** approval | QA agent (browser-qa) | *(new)* |

**Approver model (decided):** the role that authors a stage **also approves it**
(PO approves the spec, Architect approves the design). Code PRs get natural 4-eyes —
a **Reviewer cannot review their own PR**. Mandatory separate approvers on the
spec/design gates are an **Enterprise config** for later, not v1.

### 3.3 The combined check

| Action | Governance | Delivery role | Plan gate |
|---|---|---|---|
| Manage billing | owner | — | — |
| Invite / assign roles | owner / admin | — | seat limit |
| Create workspace | owner / admin | — | workspace cap |
| Create feature, author + approve spec | member+ | **PO** | — |
| Author + approve design / tasks | member+ | **Architect** | — |
| Trigger implementation agent | member+ | **Reviewer** (or Architect) | concurrency cap |
| Review PR → mark task `done` | member+ | **Reviewer** (≠ PR author) | — |
| Report a bug | member+ | **QC** (or any member) | — |
| Approve handoff (feature `done`) | member+ | **QC** + **PO** | — |
| Cancel feature / task | owner / admin **or** PO | — | — |

### 3.4 Mechanics

- **Enforcement is deterministic Go in the rules layer** — never an LLM judgement.
  The **plan → entitlement** and **delivery-role → gate** *mappings* are config/data
  (so Sales/admins can shape them without a deploy); the checks themselves are code.
- v1 ships the **fixed** governance + delivery role sets above; **custom roles** are
  an Enterprise follow-up (consistent with item 2).
- Delivery-role assignment is **per workspace** and respects the auth model's
  member/viewer workspace scoping.

### 3.5 The entitlements service (one interface)

A single service answers every authorization question so the chat surface, HTTP API,
and MCP tools never diverge. One call:

```
can(actor, action, context) -> { allowed: bool, reason }
```

It resolves the three axes in order and denies on the first failure:

1. **Plan** — does the account's effective plan (after discounts, §2.6) entitle the
   `action`? (e.g. is model-selection unlocked? under the concurrency/repo/seat cap?)
2. **Governance** — does the actor's `membership.governance_role` permit it (admin
   actions)?
3. **Delivery** — does the actor's `workspace_role.delivery_roles` include the gate
   this `action` requires (lifecycle actions), within scope?

Mappings (`plan→entitlements`, `delivery_role→gates`) are **data**; the resolver is
**code**. Reads from item 1's `membership` + `workspace_role` and item 2's account
plan/credit state.

**Decided:** **custom roles are a confirmed future capability** (post-v1, Enterprise
tier) — admins will be able to define their own roles from individual permissions on
top of the fixed preset set. v1 still ships only the presets. **Mandatory 4-eyes** on
spec/design remains a deferred Enterprise lever alongside it.

---

## 4. Workspace storage migration (GitHub → DB, compatible with v1 auth)

**Vision:** today workspace state (features/tasks/status YAML) lives in GitHub and
is read via `workspace-github-adapter`. Future: state lives in the platform DB; the
GitHub adapter is removed. **v1 must stay compatible with both.**

This is already designed into the auth spec's *Workspace Storage Independence*
section: the platform (not GitHub) is the access authority, `workspace_id` + owner
live on the platform, and the backend is a **swappable per-workspace attribute**.

**Roadmap shape:**
- **Phase A (now):** GitHub-backed only; identity layer is backend-agnostic.
- **Phase B:** introduce a DB backend behind the **same adapter contract**; new
  workspaces can opt into DB storage. Both backends run side by side.
- **Phase C:** migration tooling (GitHub → DB) + deprecate/remove the adapter.

**Thesis fit:** pure infrastructure swap; touches no rule and no gate. The lifecycle
FSM and skills should not know or care where bytes live.

**Decided:**
- **The DB backend subsumes `workflow-db`** — they reconcile into one feature, not two
  parallel datastores.
- **Losing git-as-audit is acceptable** — the gate story holds without git history.
  **But the claim protocol must change.** Today first-push-wins is enforced *by git*
  (a non-fast-forward push = lost claim). With no git in the DB backend, the task table
  needs a **lock / claim column** so an agent atomically locks a task when it picks it
  up — e.g. `UPDATE task SET status='in_progress', locked_by=:agent, locked_at=now()
  WHERE id=:id AND status='ready'` (rows-affected = 1 wins; 0 = another agent claimed
  it). This is the DB equivalent of the git-push-wins guard, and applies to every
  claim transition (`ready→in_progress`, `change_requested→in_progress`, reviewer
  dispatch). A stale-lock timeout/heartbeat handles a crashed agent.

### Suggested claim mechanism (DB backend)

The lock column is the one concrete thing the DB backend adds beyond storage parity —
but it's a small system, not a single field:

- **Dispatch** via `SELECT … FOR UPDATE SKIP LOCKED` — the Postgres job-queue
  primitive; multiple orchestrators pull ready tasks contention-free, no double-dispatch.
- **Lease, not a boolean lock:** `locked_by`, `locked_at`, `lease_expires_at`, plus a
  **`claim_epoch`** (monotonic fencing token). The agent **heartbeats** to extend; a
  reaper reclaims expired leases; the fencing token blocks a **zombie** (lapsed) agent
  from writing over the new holder.
- **Optimistic `version` column on *all* task writes** — git rejected *any*
  non-fast-forward push, so every mutation was guarded, not just the claim. Mirror with
  `… WHERE id=:id AND version=:v` (stale write → 0 rows → re-read).
- **FSM enforced in the `WHERE` clause** (required source status) — deterministic, not
  an LLM judgement; the `CLAUDE.md` transition table becomes WHERE-guards.
- **Append-only `task_event` table** replaces git-log-as-audit and feeds the unified
  event backbone.
- **One claim port, two adapters:** git-push-wins (GitHub) vs compare-and-set (DB) —
  lifecycle code identical across backends.
- **Bonus:** `LISTEN/NOTIFY` lets the DB backend go event-driven and drop the 30s poll.

### Data model delta

What the DB backend adds on top of item 1's `workspace` (which already carries
`storage_backend`):

| Table / field | Purpose |
|---|---|
| `workspace.storage_backend` (`github`\|`db`) | Which adapter serves this workspace |
| `feature`, `task`, `task_log` tables | DB-native equivalents of the YAML files (state only; narrative stays in `tasks.md`-style fields) |
| `task.status`, `task.version` | Status + optimistic-concurrency guard on every write |
| `task.locked_by`, `task.locked_at`, `task.lease_expires_at`, `task.claim_epoch` | Lease-based claim + fencing token |
| `task_event` (append-only) | Replaces git-log-as-audit; feeds the event backbone |

The **GitHub backend keeps using git** (no new tables); these exist only for `db`-backed
workspaces. The claim **port** abstracts the difference so the orchestrator core is
backend-agnostic. Reconciles with the existing `workflow-db` feature (now subsumed).

**Status: decided** — no blocking open questions remain for item 4.

---

## 5. Collaborative chat surface — real-time + agent-native

The platform's **primary human interface**: people collaborate in chat over a
feature while the deterministic lifecycle runs as the engine underneath. Think
"Linear/Slack, but the assignees can be autonomous agents." This folds together the
real-time transport and the collaboration surface that rides it — they ship as one
capability.

### 5.1 Real-time transport (build once)

- **Stream agent/chat output token-by-token** instead of batch responses — the
  table-stakes modern AI UX.
- Build **one real-time backbone** (SSE/WebSocket) reused by chat, the live board,
  agent progress, presence, and notifications — don't grow a bespoke channel per
  feature. (`gin-contrib/sse` is already in the Go backend.)

### 5.2 The collaboration surface (the copilot, in full)

**Vision (as described):** many people work in a **common chat** on a feature. A
product owner has a **private chat** to draft the product spec, then **publishes it**
for everyone to discuss; people **@tag** a teammate to act, and a Reviewer can
**trigger an agent** to do the work — all from the conversation.

- **Threaded, scoped chat** — private (PO drafting) → published (org-wide), attached
  to a feature/task. Visibility honors the permission model (item 3 — governance +
  delivery roles).
- **@mentions / tagging** — tag a *person* (assignment + notification) or an *agent*
  (trigger a worker on a task). Tagging an agent = a human explicitly invoking a
  worker — thesis-compliant. Tagging must **never** auto-advance lifecycle state.
- **Spec-by-conversation** — the PO's private draft chat is an AI copilot that
  produces `product-spec.md` *through the same `init-feature`/spec skills*, not a
  parallel writer. Publishing = the existing approve/handoff gate with a nicer surface.
- **Notifications** — in-app / email / **Slack** (already integrated per
  `workspace.yaml`).

### The critical guardrail (thesis §"the trap")

A conversational surface is exactly where "just let the agent decide" creeps in. Keep
it disciplined: chat **drafts and discusses**; **skills mutate state**; **humans
gate**; **agents are triggered, never self-dispatching from chatter.** Hold that line
and this is the product's differentiator instead of its undoing.

**Thesis fit:** a surface — it **reads the way an agent reads and mutates through the
same skills**, no chat-only write path that bypasses a gate. Choosing to build this
commits us toward a **chat-first** copilot surface (dashboard as the structured view)
— answering the thesis's open copilot-surface question.

### 5.3 Data model (sketch)

All `workspace_id`-scoped:

| Table | Key fields | Purpose |
|---|---|---|
| `thread` | `id`, `workspace_id`, `feature_id?`, `task_id?`, `visibility` (`private`\|`published`), `created_by` | A conversation, optionally attached to a feature/task; private→published lifecycle |
| `message` | `id`, `thread_id`, `author` (user **or** agent), `body`, `created_at` | Chat content; streamed via 5.1 |
| `mention` | `message_id`, `target_type` (`user`\|`agent`), `target_id`, `resolved` | @tag a person (assign+notify) or an agent (trigger a worker) |
| `notification` | `user_id`, `source` (`mention`/`gate`/`review`/…), `channel` (`in_app`/`email`/`slack`), `state` | Delivery + read state |
| `thread_event` | `thread_id`, `action` (`published`/`agent_triggered`/…), `actor`, `at` | Audit; shares the event backbone |

Key rule encoded in the model: a `mention` of an agent **enqueues a worker dispatch**
(through the existing skill/claim path) — it does **not** write task status. Lifecycle
transitions only ever come from skills, never from `message` rows.

### 5.4 Decided / open

**Decided:**
- **Chat-first** is the copilot-surface bet (dashboard = structured view).
- One **real-time transport** (5.1) reused everywhere; `gin-contrib/sse` is the start.
- Tagging an agent = explicit worker dispatch; **never** auto-advances lifecycle state.

**Open:**
- Notification fan-out scope for v1 (in-app only, or email/Slack too on day one?).
- Whether published threads are org-wide or scoped to workspace members (default:
  workspace members per item 3 scoping).

**Depends on:** auth (1); permissions (3) for chat visibility + roles. 5.2 rides the
5.1 transport.

---

## 6. Source-control integration — bot identity + multi-repo workspaces

Two coupled capabilities that turn "our repos under one account" into "any
customer's VCS." Both build on the in-flight `workspace-github-adapter` work
(multi-token, multi-repo sync) and together **resolve item 1's open GitHub
repo-access decision** — it's a VCS *App*, not a PAT.

### 6.1 Platform bot identity (commit-as-bot)

Agents must commit, push, and open PRs to a customer's repos as an **identifiable,
revocable machine actor** — not as the human user, and not as a shared global key.

- **Mechanism:** a **GitHub App** (and the **GitLab** equivalent — group/project
  access token or bot user) that appears as e.g. `digital-factory[bot]`. Each
  customer org gets its **own installation** with fine-grained, **revocable**,
  per-install tokens (`contents:write`, `pull_requests:write`, …).
- **Org grants the permission (the feature you described):** an org admin
  **installs the app** on their org or a selected set of repos and authorizes the
  scopes. Revocable any time from their side and ours. This is a governance action
  (owner/admin per item 3).
- **Credential storage:** installation tokens/refresh live server-side, account-
  scoped — this is one of the things that promotes the deferred **credential vault**
  to a near-term feature.
- **Thesis fit:** the bot is a *worker* identity. Bot commits still land via PRs
  that a human **Reviewer** gates — the bot never bypasses a gate.

### 6.2 Bind a VCS org + multiple repos to a workspace

- Today a workspace ≈ a fixed set of repos under one account. For SaaS, a workspace
  **binds to a customer's VCS org + a selected set of repos** (management repo +
  impl repos), and the bot (6.1) is authorized on exactly those repos.
- **Provider-agnostic** (GitHub or GitLab) and consistent with item 4's swappable
  storage-backend contract — the binding records *which provider/org/repos*, the
  backend records *where state lives*.
- A workspace may span **multiple repos**; a customer org may host **multiple
  workspaces**. Access still flows through the platform's permission model (item 3),
  not the VCS's own repo permissions.

### 6.3 Billing impact (per your note)

- **Connected repos** (and/or connected VCS orgs) become a **plan dimension + a
  metered resource**, enforced in the entitlements layer (item 3) like seats and
  workspaces — e.g. Free 1 repo, Pro a few, Team/Enterprise many/unlimited.
- Metering already records repos (item 2.3); this makes them a billable/capped axis,
  not just a number on a dashboard.

### 6.4 Data model (sketch)

| Table | Key fields | Purpose |
|---|---|---|
| `vcs_connection` | `id`, `account_id`, `provider` (`github`\|`gitlab`), `org_slug` | A customer VCS org linked to an account |
| `bot_installation` | `vcs_connection_id`, `install_id`, `scopes`, `token_ref`, `status` | The App install + its revocable per-install token (secret in the vault, not inline) |
| `repo_binding` | `workspace_id`, `vcs_connection_id`, `repo`, `role` (`management`\|`impl`) | Which repos belong to a workspace; the bot is authorized on exactly these |

The **bot acts via `bot_installation` tokens**, scoped to `repo_binding` repos only;
revoking the install (either side) kills access immediately. `token_ref` points into
the credential vault — raw tokens are never stored in these rows.

### 6.5 Decided / open

**Decided:**
- Repo access is a **VCS App + bot identity** (resolves item 1.2), not a user PAT.
- The **org admin grants** the install (governance action, item 3); revocable both sides.
- A workspace binds **one VCS org + many repos**; access still flows through the
  platform permission model, not the VCS's own repo permissions.

**Open:**
- GitLab parity timing (GitHub App first, GitLab equivalent fast-follow?).
- Exact per-tier **connected-repo caps** (a marketing/plan number, like the §2.7 set).

**Depends on:** auth (1) for the org + governance grant; credential vault for token
storage; the `workspace-github-adapter` multi-repo work already underway.

---

## Cross-cutting ideas worth stealing

Beyond the six, a few things fall out of looking at them together:

1. **One entitlements service, three axes (governance role × delivery role × plan).** Single answer to "can this
   actor do this here?" Consumed by chat, HTTP, and MCP identically.
2. **Metering as a platform primitive, not a billing detail.** It powers billing,
   quotas, cost dashboards, *and* abuse/runaway-cost detection. Build it deliberately.
3. **Cost guardrails / budgets.** Autonomous agents that spend tokens are a runaway-
   cost risk. Per-workspace and per-org **spend caps with alerts and auto-pause** are
   arguably a *safety* feature, not just billing. Enterprises will demand it.
4. **One real-time backbone.** Chat, live board, agent progress, presence,
   notifications — all the same transport.
5. **Unified event/audit backbone.** The auth audit log, the activity feed, the chat
   timeline, and metering events are all "things that happened." One append-only event
   stream can feed all of them and gives Enterprise the auditability the thesis says
   buyers pay for.
6. **API keys & programmatic access.** Once orgs exist, Enterprise will want scoped
   API tokens and (per the agent-native thesis) MCP access governed by the same
   entitlements. Natural companion to billing/metering.
7. **The deferred credential vault (from the auth spec) becomes load-bearing here.**
   Server-side secret storage is a non-goal in auth v1, but GitHub repo-access tokens,
   **customer BYO provider keys** (Anthropic/OpenAI/Gemini/…), and the DB-backed
   workspace all want it. Worth promoting to its own near-term feature once auth lands.
8. **Model gateway (§2.5) is foundational, not optional.** A multi-provider gateway
   (Anthropic, OpenAI, Gemini, DeepSeek, …) is where routing, per-model token→credit
   conversion, managed-vs-BYO funding, metering, and fail-over all live. It is the
   engine the whole billing model sits on.

---

## Implementation plan — stages & timeline

Ordered by **dependency**, not by excitement. The rule that sets the order: *you
can't meter what has no owner, can't bill what you don't meter, can't gate by plan
without a permission model, and can't build the chat surface without all of it.*
**Auth is first; Enterprise hardening is last; the chat surface is the payoff in the
middle-late.**

Sizes are T-shirt (S ≈ days, M ≈ 1–2 wks, L ≈ 3–5 wks, XL ≈ 6 wks+) for *one small
team*; absolute dates depend on headcount.

### Stage 0 — Identity foundation **(do first)**
*An account exists and you can sign in. Nothing else can start without this.*

| Part | From | What it is | Size |
|---|---|---|---|
| Build-vs-buy decision | Q **1.1** | Managed provider vs self-hosted Go — gates the stage | — |
| Identity data model | item 1 *Data model* | `account`, `user`, `auth_identity`, `membership`, `workspace`, `workspace_role`, `session` | L |
| Sign-in | item 1 §*Decisions* / Phase 1 | email+password (verify, reset), Google + GitHub OAuth, account linking | M |
| Account model | item 1 §*Decisions* | personal (org-of-one) + org accounts + context switching | M |
| Governance roles | item 3 **§3.1** | owner/admin/member/viewer + per-workspace scoping (on `membership`) | M |

**Exit:** sign up → create/join org → switch context; access decided by the platform,
not GitHub. *(The `workspace_role` table is created here; wiring delivery roles to
gates is Stage 3.)* **Blocks everything.**

### Stage 1 — Machine identity & repo access
*Agents can commit to a customer's repos as a revocable bot. Overlaps tail of Stage 0.*

| Part | From | What it is | Size |
|---|---|---|---|
| Credential vault (minimal) | cross-cutting #7 | server-side secret store for bot tokens (`token_ref`) | M |
| Bot identity | item 6 **§6.1** | GitHub/GitLab App, per-install revocable tokens, org-admin grant/install | L |
| Org + repo binding | item 6 **§6.2 / §6.4** | `vcs_connection`, `bot_installation`, `repo_binding` | M |

**Exit:** an org admin installs the App, binds repos, and the bot opens a PR. Resolves
Q **1.2**. *Needs:* org + governance grant from Stage 0.

### Stage 2 — Metering & model gateway **(billing substrate)**
*Every model call is routed, measured, and converted to credits.*

| Part | From | What it is | Size |
|---|---|---|---|
| Model gateway | item 2 **§2.5** | multi-provider routing (Claude/OpenAI/Gemini/DeepSeek), managed/BYO switch, fail-over | L |
| Conversion table | item 2 **§2.2** | per-model token→credit rates the gateway applies | S |
| Metering ledger | item 2 **§2.3** | tokens/runs/repos, `workspace_id`-scoped, raw + credits + managed/BYO flag | M |

**Exit:** a run shows up in the ledger as credits, attributed to a workspace. *Needs:*
accounts (Stage 0) to attribute usage.

### Stage 3 — Billing, entitlements & permissions **(monetization)**
*Usage becomes revenue; actions are gated by plan + role.*

| Part | From | What it is | Size |
|---|---|---|---|
| Entitlements service | item 3 **§3.5** | the one `can(actor, action, context)` rail | M |
| Delivery roles → gates | item 3 **§3.2 / §3.3** | PO/Architect/Reviewer/QC wired to lifecycle gates | M |
| Plan model + pricing | item 2 **§2.1 / §2.7 / §2.4** | tiers, allowances, overage, **spend-cap/auto-pause**, Stripe | L |
| Discount engine | item 2 **§2.6** | coupons/OSS/non-profit/annual, configurable | M |

**Exit:** a Team org pays; an action passes only when plan + governance + delivery all
agree; overage auto-pauses at the cap. *Needs:* metering (2) + accounts/roles (0).

### Stage 4 — Collaborative chat surface **(the differentiator)**
*People and agents collaborate in chat over the lifecycle.*

| Part | From | What it is | Size |
|---|---|---|---|
| Real-time transport | item 5 **§5.1** | SSE/WebSocket backbone, reused everywhere | M |
| Chat + tagging | item 5 **§5.2 / §5.3** | `thread`/`message`/`mention`/`notification`; @tag person or agent | L |
| Spec-by-conversation | item 5 **§5.2** | PO copilot that drafts the spec *through the spec skills* | M |

**Exit:** a PO drafts a spec in chat, publishes it, tags a Reviewer/agent, work runs —
no chat path bypasses a gate. *Needs:* Stage 0 + Stage 3 (visibility/roles).

### ‖ Parallel track — Storage DB backend (item 4)
*Runs on its own track start-to-finish; touches no gate, so it never blocks the
critical path. Gated only by the (resolved) git-as-gate question.*

| Part | From | What it is | Size |
|---|---|---|---|
| Claim port + adapters | item 4 §*claim mechanism* | git-push-wins vs compare-and-set, one orchestrator-facing port | M |
| DB backend | item 4 §*data model delta* | `feature`/`task`/`task_event`, lease/fencing/`version`, `LISTEN/NOTIFY`; subsumes `workflow-db` | L–XL |

### Stage 5 — Enterprise hardening **(do last, demand-driven)**
*Close enterprise deals. Pulled forward only by specific demand.*

| Part | From | What it is | Size |
|---|---|---|---|
| Hosting decision | Q **X.1** | SaaS vs customer-hosted vs hybrid — shapes the rest | — |
| Account security | item 1 **Phase 2** | MFA/passkeys, session/device mgmt, step-up auth, recovery | L |
| Enterprise identity | item 1 **Phase 3** | SSO/SAML+OIDC, **SCIM**, verified-domain, IP/session policy, residency, audit export | XL |
| Custom roles + 4-eyes | item 3 *deferred* | fine-grained roles, mandatory spec/design approvers | M |
| Machine/delegated | item 1 **Phase 4** | service accounts + API/MCP tokens, audited impersonation, ownership transfer | M |

**Exit:** an enterprise can SSO in, auto-provision via SCIM, and (if needed) self-host.

### Critical path & timeline

**Critical path:** `Stage 0 → Stage 2 → Stage 3 → Stage 4`. Stage 1 (VCS/bot) and the
Storage track run alongside; Stage 5 trails as demand-driven.

Illustrative calendar for one small team (relative, **not committed dates**):

```
        M1   M2   M3   M4   M5   M6   M7   M8+
Stage0  ███████████                                 identity foundation
Stage1       ██████████                             VCS App + bot + vault
Stage2            ██████████                         metering + model gateway
Stage3                 ████████████                  billing + entitlements + perms
Stage4                          ███████████          collaborative chat surface
DB ‖    ░░░░░░░░░░░░░░░░░░░░░░░░                      storage backend (parallel track)
Stage5                                  ░░░░░░░░░░→   enterprise hardening (ongoing)
```

**First three things to build, in order:** (1) the **auth backend + account/org model**
(decide build-vs-buy), (2) the **VCS App + bot identity** so agents can act on customer
repos, (3) the **model gateway + metering** so usage is measurable. **Last:** Enterprise
identity (SSO/SCIM/residency) and customer-hosted — biggest lift, least blocking, sold
into deals rather than built speculatively.

---

## Decisions this roadmap is implicitly asking us to make

These map directly onto the thesis's "what this thesis does not yet decide":

- **Pricing model** → item 2. Decided: 5 tiers, included allowance + metered overage,
  spend-cap/auto-pause, normalized **credits** with per-model conversion, **managed
  or BYO** funding on every tier.
- **Vendor lock-in** → **multi-provider** (Anthropic, OpenAI, Gemini, DeepSeek, …)
  behind our model gateway, plus BYO key. We are not locked to one vendor, and
  customers aren't locked to us.
- **Copilot surface shape** → item 5 commits us to **chat-first** (with the
  dashboard as the structured view). Is that the bet we want?
- **Hosting model** (SaaS vs customer-hosted) — *still unaddressed here.* It strongly
  affects the credential vault, the DB backend, and Enterprise data-residency.
  Flagging it as the one big gap this roadmap does **not** yet cover — worth a
  dedicated discussion.
