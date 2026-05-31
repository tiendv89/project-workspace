# Product Thesis

> **What we are building**
> A software delivery team whose members are both humans and agents — running on a deterministic spine.
>
> **What we are not building**
> An agent that *interprets* the rules of the SDLC at runtime.

This is the one-page floor under every product decision. Re-read it when you are unsure whether to pivot, when a feature proposal includes the phrase "let the agent decide", or when marketing copy starts drifting toward "autonomous engineering". The product is the team described below; the deterministic spine — see [The spine](#the-spine-why-a-team-of-agents-is-saleable) — is what makes that team something an enterprise can buy.

## The vision: a team of humans and agents

The product is **a development team whose members are both humans and agents**, working the same feature in the same place, with the deterministic lifecycle running underneath as the engine. People and agents share the same threads, pass through the same gates, and mutate state through the same rails. This is the product — not a future phase of it — and every feature, surface, and roadmap item should bend toward it.

**The coding executor is the first worker — one part of the product, not the whole.** The most-built piece today is an agent that does bounded code work inside a task whose lifecycle is governed by deterministic rules. That worker is still valid and still central. But it is *a* member of the team, not the definition of the product. The product is the team; the code executor is the first kind of teammate we shipped. The vision has three dimensions — the worker broadens, the worker deepens, and the gate stays deterministic.

**What expands — the breadth of the worker.** Today an agent is a code executor. Next it becomes a *teammate*: an agent you can `@mention` in a feature thread to draft a product spec, propose a technical design, review a PR, file a QA report, or answer a question — and that can `@mention` *you* back when it needs input or a decision. The four-layer table names "future fix agents and design agents," and "Why this framing matters" says to *aggressively agentify everything inside a task — code, design, review, QA, doc drafting*. The teammate is that taken to its end: an agent that participates in the conversation the way a human teammate does, not just a tool that runs when scripted.

**What deepens — the worker learns.** These teammates are built on **Hermes** ([Nous Research's open agent](https://github.com/nousresearch/hermes-agent)). Hermes agents carry a **learning loop and persistent memory**: they build procedural know-how from experience, search their own past conversations, persist knowledge, and deepen a model of the people and the codebase across sessions. A Hermes teammate in week ten knows the workspace better than it did on day one. It is **model-agnostic** by design, so it slots cleanly behind our multi-provider model gateway (roadmap §2.5) rather than locking us to one vendor.

**What must not change — the gate stays deterministic and permission-governed.** This is where the central trap *seems* to reappear — "won't a team-member agent end up running the SDLC?" — and where the distinction has to be drawn precisely. The trap was never "an agent passes a gate." The trap is "an **LLM interprets, at runtime,** whether a gate may pass." Those are different things. An actor — human **or** agent — passes a gate by **exercising authority the permission system granted it**, through the deterministic skill/claim path. That is not bypassing the gate; that is the gate working as designed.

So for a Hermes teammate that has been granted authority:

- It **acts within its granted authority.** Given the permission, an agent **can** self-dispatch (claim a ready task and start) and **can** advance lifecycle state — the same way a human delivery-role holder does, through the same skills and the same deterministic transition checks. Without that grant it acts only when tagged. What it never does is *invent* authority it wasn't given, or let an LLM decide at runtime that a transition is "probably fine."
- **Authority is assigned, not assumed.** Whether an agent may approve a spec, advance a task, or trigger another agent is a **permission** decision — entitlements (plan × governance role × delivery role, roadmap §3), resolved by deterministic code over config/data. The org chooses how much to delegate; the system enforces the same check for human and agent actors. "Rules run the process" is the invariant; **"*humans* hold the gates" relaxes to "*permissioned actors* hold the gates,"** and an org may grant a trusted agent one.
- Its **learning makes the worker better, not more authorized.** Authority comes only from an explicit grant — never from tenure, fluency, or accumulated memory. A Hermes teammate that has learned the codebase cold still cannot advance a gate it was not granted; a freshly-spun agent *with* the grant can. *(Mind the word collision: a Hermes "skill" is **procedural memory the agent learns** — the worker getting better at its job. Our **Skills layer** is deterministic tooling that executes rules. A learned skill never edits a rule and never becomes a new path to mutate state.)*

### The shape of the surface

Concretely, the surface is the collaborative chat sketched in the roadmap (§5), read through the team-of-agents lens:

- A **feature is the unit of collaboration.** It holds **many sessions (threads)** — a PO's private spec-drafting session, an open design discussion, a per-task work thread. (`thread.feature_id`, roadmap §5.3.)
- **Humans and agents share the thread.** People chat the way they would in Slack/Lark; an agent teammate, when `@mentioned`, picks up the work on its task and posts back — and `@mentions` a human when it needs a decision or input. A `message.author` is a user **or** an agent.
- The teammate's **memory spans the workspace**, so context carries across threads and features instead of resetting per task — scoped by `workspace_id` like everything else.

This is the differentiator: *Linear/Slack where some of the assignees are autonomous, learning agents* — riding a spine an enterprise can audit, because every state change still passes through a deterministic gate, never through the conversation.

## The spine: why a team of agents is saleable

A team of agents is only a product an enterprise will buy because of what sits under it. The spine is the deterministic lifecycle — and protecting it is the discipline that separates this from "an LLM in a loop."

The word *agent* gets used to mean two incompatible things:

1. **Decision-maker** — an LLM "decides" whether a task can advance, who claims it, whether a feature is approved, what the next step is.
2. **Worker** — an LLM does the code work *inside* a task whose lifecycle is governed by deterministic rules.

Our workers are the second kind. The first is the trap.

Buyers (enterprise delivery teams, regulated orgs, anyone shipping to production) pay for **predictability**: that the same task hits the same gates in the same order every time, with auditable state and reproducible review. The moment an LLM gets to "interpret" whether T3 can move to `in_review`, that promise breaks — and the system loses the only thing it has that an LLM-in-a-loop does not. Note the precise boundary: a *permissioned* agent passing a gate through the deterministic check does not break this — an LLM *interpreting* whether the gate may pass does.

Whenever you feel the pull to "just let the agent handle it" at a workflow boundary, stop. That pull comes from the surface (LLMs feel magical) and ignores the spine (rules are what make the system saleable).

## The four layers

The product is a layered system. Each layer has a different operating principle and a different rate of change. Confusing them is the most common architectural mistake we can make.

| Layer | What it is | Operating principle |
|---|---|---|
| **Rules** | Lifecycle FSM, status transitions, dependency unblocking, claim protocol, file-scope rule, branch protocol, rebase rules, gate semantics | Deterministic code. No LLM in the loop. Changes via versioned feature work, never at runtime. |
| **Skills** | `start-implementation`, `pr-create`, `approve-feature`, `init-feature`, `respond-to-review`, … | Procedural, scriptable, side-effect-explicit. Skills *execute* rules; they do not negotiate them. |
| **Agents** | Claude Code sessions inside the executor; reviewer agents; future fix agents and design agents | Non-deterministic workers. Bounded to one task each. Read freely; mutate only via skills and MCP tools. |
| **Humans** | Product owner, tech lead, reviewer | Gate-holders by default. Approvals and stage transitions are theirs — unless an org grants an agent a delivery role, in which case a permissioned agent holds them through the same deterministic check. Agents prepare work; permissioned actors accept or reject it. |

**Rules are code. Skills are tools. Agents are workers. Permissioned actors hold the gates.** All four layers exist. None replaces another — and the gate-holder is a role granted by the permission system, not a fixed property of being human.

## Why this framing matters

It tells us what to *not* agentify: lifecycle, gates, claims, dependencies, file scope, branch hygiene. These are the spine.

It tells us where to *aggressively* agentify: anything that happens inside a single task — code, design, review, QA, doc drafting, refactor proposals. These are the bicep.

It gives a one-sentence pitch that survives technical scrutiny: **"AI does the work, rules run the process, permissioned actors hold the gates."** No buzzword salad, no claims the system cannot keep. (The floor-state reading — *humans* hold the gates — is just the case where an org has granted no agent a delivery role.)

It tells us how to evaluate every new feature proposal: *does this change a rule, a skill, an agent capability, or a surface?* Each answer has a different review bar.

## Surfaces are agent-native by default

A *surface* is anything outside the spine — HTTP APIs, MCP servers, dashboards, IDE integrations, chat copilots. Every surface should be reachable by an LLM client without a human in the loop.

In practice this means:

- Every read API has an MCP tool.
- Every write API has an MCP tool whose semantics are identical to the HTTP equivalent — no parallel logic, no separate validation path.
- A human copilot (chat surface) reads the same way an agent does and mutates through the same skills.

The point is not "MCP everywhere because MCP is trendy." The point is that **one set of rails serves both human and agent clients**, so we never maintain two divergent paths to the same state, and we never invite a client to bypass the gate.

## Positioning

Avoid: "agent platform", "AI software developer", "autonomous engineering".

Prefer: **"agent-native delivery system"**, **"AI-managed SDLC with deterministic gates"**.

The first set sells magic and invites scepticism from procurement, security, and audit. The second sells rails and invites trust. Both are technically true; only the second survives a real enterprise sales cycle.

This holds even though an org *can* grant an agent a delivery role and let it hold gates (see [The vision](#the-vision-a-team-of-humans-and-agents)). We avoid "autonomous engineering" not because the system forbids delegated autonomy, but because the phrase implies an LLM *interpreting* the process at runtime — the one thing we never allow. A permissioned agent passing a gate is still rails, not magic: the same deterministic check, just a different actor granted authority over it.

## What this thesis does not yet decide

- Pricing model (per-seat vs per-task vs per-workspace).
- Hosting model (SaaS vs customer-hosted vs hybrid).
- Vendor lock-in posture (Anthropic-only vs multi-vendor for agents).
- Shape of the copilot surface (chat-first vs dashboard-first vs IDE-first).

These are deliberate gaps. The thesis is the floor, not the roadmap.

## Self-check, before making a major product decision

1. Does the proposal move something from the **Rules** layer into the **Agents** layer? → almost always wrong. Push back.
2. Does it create a new surface that bypasses the existing skills/MCP rails? → wrong. Make it use the same rails.
3. Does it agentify something *inside* a task (code, review, design)? → almost always right. Pursue.
4. Does it let an actor pass a gate by *interpretation* rather than by *granted permission*? → wrong. That is the trap.
5. Does the marketing copy say "autonomous"? → rewrite.
