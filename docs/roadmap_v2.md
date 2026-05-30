# Platform Roadmap v2 — Milestone-Based

> Status: **draft for discussion**, not an approved plan.
> This is a second cut of the roadmap, ordered by **milestones** — sellable / provable
> increments — rather than by time. The ordering principle is **value and risk retired**,
> not dependency purity: each milestone either *deepens the product* or *kills the biggest
> open unknown* next.
>
> **The starting point is a services business, not a greenfield product.** We already sell
> delivery as a service and our worker team (humans + agents) already delivers — so the
> first dollar is not the unknown. The unknown is whether exposing that delivery to the
> client turns a services engagement into a product. M1 is therefore a **services → product
> transition**, not a "smallest payable SaaS."
>
> The dependency-ordered view still lives in [`roadmap.md`](./roadmap.md) — keep it as
> the engineering "what is safe to build next" reference. This doc is the
> "what is smart to build next" companion.

It sits under [`product-thesis.md`](./product-thesis.md) — re-read that first. Two
deliberate departures from v1, both thesis-driven:

1. **The differentiator comes early — and in the right order.** First we build the actual
   agent (M2, Hermes — today we have only a coding *worker*, not a conversational
   teammate), then we integrate the front-end + ecosystem around it (M3, The Thread). Both
   land *before* the billing engine (M4). Prove the magic before building the cash register.
2. **No monetization machinery up front.** Because we sell by hand today (B2B, invoiced),
   M1 builds **no self-serve payment, no BYO-key logic, no metering, no tiers.** It builds
   the identity/org/workspace spine and a client-visible surface. The billing engine is
   deferred to M4, when strangers start signing up unattended.

It also closes a thesis↔roadmap gap: **Hermes** (the conversational, learning agent the
thesis leans on) had no line item in v1. Here it is **M2**, its own milestone — and it
comes *before* the collaboration surface, because there is no agent to put in the thread
until Hermes is deployed.

---

## The milestones at a glance

```
  M1  Open the Black Box             → client logs in and watches the delivery (identity + visibility)
  M2  The Teammate                   → deploy the Hermes agent: conversational + learning (worker → teammate)
  M3  The Thread                     → integrate FE + ecosystem so humans + agents collaborate in a feature
  M4  Meter & Monetize               → metering, credits, tiers, caps, discounts (monetization maturity)
  M5  Delegate the Gate              → a permissioned agent holds a delivery role (the North Star)
  M6  Enterprise Trust               → SSO/SCIM, residency, custom roles, SOC 2 (demand-pulled)

  ‖   Enabling tracks                → DB storage backend · model gateway · credential vault
```

The early milestones retire **product risk** ("does anyone want this?"); the later ones
retire **commercial scale risk** ("can we monetize and sell upmarket?"). We do not build
the cash register before we know the magic works.

---

## M1 — Open the Black Box

*Give the client a window into the delivery they are already paying for.*

**The reality we start from.** We already sell delivery as a service; our worker team
(humans + agents) already delivers. The gap is not revenue — it's that the **client never
sees the team or the process.** They hand us a project and receive output. M1 cracks that
black box open: the client logs in and watches their delivery happen.

- **The sell:** not a new SKU — the *same* engagement, now visible. The client sees its
  workspace: features, tasks, progress, and what the worker team (human + agent) is doing.
  This is the first step from **services → product**.
- **Build — the identity *data model*, not auth mechanics:**
  - `user` (profile), `account`/`org`, `workspace`, `membership` (user ↔ org ↔ role),
    per-workspace scoping. The spine every later milestone hangs off.
  - **Federated login only — Google + GitHub.** We consume them as identity providers and
    build the **profile + org/workspace layer** on top. (A thin session/cookie layer after
    the IdP hands back identity — library-handled glue, *not* an auth system.)
  - **The client visibility surface — strictly read-only.** A logged-in client org
    *watches* its workspace and delivery progress. The client's only input is the spec,
    handed over **offline / off-platform** for now; there is no spec-submission feature in
    M1. They observe; they do not act.
- **Explicitly NOT built:** no client actions of any kind — **no commenting, no approving,
  no @mentioning, no spec-drafting in-product** (all of that is M2+); no password /
  OAuth-server of our own; no Stripe or self-serve payment (we invoice by hand); no BYO
  key, no metering, no tiers, no billing; no GitHub App / bot yet (the team already
  operates on the repos as it does today).
- **Bonus of choosing GitHub as a provider now:** the same GitHub identity that logs a
  client in can later authorize repo access for the bot milestone — the choice pays off
  downstream.
- **Kills the unknown:** *does letting the client watch the delivery create enough
  perceived value and stickiness to make this a product, not just an agency?*

## M2 — The Teammate *(Hermes — build the actual agent first)*

*The worker becomes an agent: it can interact, converse, and learn.*

**Why this comes before the chat surface.** Today we have a **coding worker**, not an
agent — it claims a task, produces a PR, and stops. It cannot hold a conversation,
participate, or carry context. You cannot build "The Thread" (M3) on top of that, because
there is **no agent to put in the thread yet.** So M2 builds the agent itself.

- **The shift:** *worker → teammate.* The model is **a team working on a feature** — whose
  members happen to be human or agent — not "a human directing an agent." The agent
  interacts the way you and I are interacting now, in that team-on-a-feature mode.
- **The output is a deployed Hermes agent.** That is the milestone's definition of done: a
  running Hermes agent that can converse/participate **and** carry **workspace-scoped
  persistent memory + a learning loop** — it knows the workspace better in week ten than on
  day one. Model-agnostic behind the gateway.
- **Dogfooded first.** The agent can be exercised by our own delivery team before any
  client-facing surface exists — M2 proves the *capability*, M3 exposes it.
- **Discipline:** learning makes the worker *better*, never *more authorized* — authority
  stays a separate, explicit grant (see M5).
- **Kills the unknown:** *can we turn our coding worker into a genuine conversational,
  learning agent teammate at all?* — the foundational capability the whole product rests on.

### M2 deployment model — resident teammate on a VM

The reference point is the faro Hermes deployment (`bet-14`), which runs Hermes as a
**multi-tenant K8s service** — stateless pods, tools stripped, all per-user state pushed to
a Redis/S3 write-behind cache, every session scoped by `user_id`. That design exists to
*fight* Hermes's single-user, local-first nature because faro needs a shared chat backend.

**We do the opposite — embrace the grain.** Hermes runs as **a resident teammate: one
agent instance per workspace, on its own small VM, with that VM as its workstation.**

- **Two clean layers — the agent is the *member*, not the *hands*:**

  | Layer | Does | Runs | Concurrency |
  |---|---|---|---|
  | **Hermes agent** (new, M2) | converse, reason, remember/learn, coordinate, **dispatch the worker** | resident process on a small VM | many threads — light, I/O-bound |
  | **Coding worker** (existing, unchanged) | edit code, run tests, git, open PR | per-task executor/container, as today | per-task isolation |

- **The existing coding worker does not change.** Hermes never touches a working tree — it
  only makes LLM/tool calls and triggers the worker through the existing skill/claim path.
  Code execution stays with the per-task worker layer that already scales on its own.
- **Parallelism is not a constraint.** One resident agent handles many discussions easily
  (interleaved, I/O-bound — like a person with many open threads). Code-execution
  parallelism is the worker layer's job, per task, exactly as today. The VM stays small —
  it is a coordinator, not a build box. A *second* agent is only ever for deliberate
  **identity separation** (e.g. reviewer-agent ≠ implementer-agent for 4-eyes), never for
  throughput.
- **Single-tenant by construction → faro's multi-tenant hardening is unnecessary.** One
  agent sees one workspace, so full tools are fine (the VM is the sandbox, like a dev's
  laptop) and the cross-user leakage faro's §3.7 fights cannot occur.
- **Memory is native and local — one brain.** `MEMORY.md` / `skills/` live on the VM disk;
  the learning loop (`background_review`) is native Hermes behaviour with no extra infra.
  Knowledge is **workspace-scoped by construction** because the agent only ever works one
  workspace. *Keep one piece of faro's design:* periodic **snapshot of the agent's home to
  durable storage** — for backup of the agent's accumulated knowledge, not for tenancy.
- **Kept from faro:** multi-provider behind the model gateway (OpenAI-compatible contract,
  provider chosen from mounted keys) — the thesis's "model-agnostic" point.
- **Scope note:** M2 delivers the Hermes deployment itself. Defining what a "session" /
  "session-end" is for us — and therefore when `background_review` runs to bank what the
  agent learned — is an **M3 concern** (it depends on the thread/lifecycle integration), not
  an M2 blocker.

## M3 — The Thread *(integrate the agent into the product)*

*Put the team — human and agent — in one place, working a feature.*

- **The sell:** the thesis made real — *Linear/Slack where some of the assignees are
  agents.* With the Hermes agent now deployed (M2), M3 is the **front-end + ecosystem
  integration** that lets humans and agents collaborate in a feature. It is also where the
  client moves from **watching** the delivery (M1) to **participating** in it.
- **Core:** the collaborative chat surface + real-time transport, `@mention` a person or a
  **Hermes agent**, the agent participates and posts back, **humans still gate**; delivery
  roles (PO / Architect / Reviewer / QC) enter here, because multi-actor collaboration
  needs them; wiring into the existing ecosystem (lifecycle, skills, notifications).
- **Guardrail (thesis "the trap"):** chat drafts and discusses; skills mutate state;
  permissioned actors gate; agents are triggered, never self-dispatching from chatter.
- **Owns the session definition:** because the thread/lifecycle integration lands here, M3
  defines what a "session" / "session-end" is — natural mapping: **session = a task/thread;
  session-end = it reaches a terminal state**, which is when the M2 agent's
  `background_review` runs to bank what it learned.
- **Kills the unknown:** *does the team-of-humans-and-agents loop actually delight
  someone?* — the biggest bet in the whole thesis.

## M4 — Meter & Monetize *(monetization maturity)*

*Turn a flat BYO fee into a real pricing engine — once we know what people value.*

- **Core:** metering ledger, model-gateway managed mode, normalized credits + per-model
  conversion table, the full tier ladder (Free / Pro / Max / Team / Enterprise),
  spend-cap / auto-pause, per-workspace cost dashboard, discount engine.
- **Why here, not first:** every number in v1's billing chapter is an untested assumption
  today. Build it against real usage, not guesses.
- **Enforcement stays in the spine:** plan → entitlement mapping is config/data;
  enforcement is deterministic code, never an LLM judgement.

## M5 — Delegate the Gate *(the North Star capability)*

*A permissioned agent can hold a delivery role and advance state — through the same
deterministic check a human uses.*

- **Core:** entitlements-service maturity, granting an agent a delivery role, agent
  self-dispatch *within granted authority*. "Permissioned actors hold the gates," made
  literal.
- **Why this late:** it only makes sense once roles, entitlements, and a trusted learning
  teammate (M2) all exist. The invariant never relaxes — an LLM still never *interprets*
  at runtime whether a gate may pass; it exercises authority the permission system granted.

## M6 — Enterprise Trust *(demand-pulled)*

*Everything procurement and security ask for.*

- **Core:** SSO/SAML + OIDC, **SCIM** provisioning (**buy this layer — don't hand-build**),
  data residency / regional hosting, custom roles + mandatory 4-eyes, audit export / SIEM
  streaming.
- **Start early, ship late:** **SOC 2 readiness begins the day we chase the first
  enterprise deal**, not at the end of the build.

---

## ‖ Enabling tracks (slot where needed, never block the value path)

- **Storage DB backend (GitHub → DB).** Runs on its own track; touches no gate. Flag
  "losing git-as-audit" as a **positioning** decision (immutable audit in the customer's
  own GitHub is a trust asset), not just an engineering one.
- **Model gateway.** Minimal for BYO routing in M1; matures into the managed/credits
  engine for M4.
- **Credential vault.** Promoted to a real feature the moment server-side secrets are
  needed — bot tokens and customer BYO provider keys (around M1 → M4).

---

## What changed from v1, and why

1. **It starts from a services business, not greenfield.** M1's job is to productize an
   already-running, already-paid delivery operation by making it visible to the client —
   not to invent a payable SKU from scratch.
2. **The agent (M2) and the collaboration surface (M3) now precede the billing engine
   (M4) — and in that order.** Build the conversational, learning agent first; integrate
   the FE/ecosystem around it second. v1 buried both behind a quarter of monetization
   plumbing *and* assumed an agent that could already converse. Risk-first says prove the
   magic before building the cash register.
3. **No monetization machinery in M1.** Because we sell by hand (B2B, invoiced), the first
   milestone builds the identity/org/workspace spine and a client-visible surface — no
   payment, no BYO, no metering, no tiers. All of that is deferred to M4.
4. **We don't build auth — we federate it.** Google + GitHub as identity providers; we
   build only the user-profile + org/workspace model on top.
5. **Hermes has a home — and the right slot.** The conversational, learning agent the
   thesis leans on is now an explicit milestone (M2), placed *before* the collaboration
   surface because the thread needs an agent to hold.
6. **Enterprise identity leans buy, not build** (SSO/SCIM), consistent with the decided
   SaaS hosting posture.

> **Open for discussion next:** define M1's exact cut line — the identity/org/workspace
> data model and the (read-only) client visibility surface: which delivery state the
> client sees and how it's presented. The seam is firm — **M1 and M2 are watch-only from
> the client's side (M2 builds and dogfoods the agent); client participation opens in M3
> (The Thread).** Then we can detail M2 — what "a deployed Hermes agent" must actually do.
