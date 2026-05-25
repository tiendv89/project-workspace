# Product Thesis

> **What we are building**
> An agent-native software delivery system with deterministic gates.
>
> **What we are not building**
> An agent that "runs" the SDLC.

This is the one-page floor under every product decision. Re-read it when you are unsure whether to pivot, when a feature proposal includes the phrase "let the agent decide", or when marketing copy starts drifting toward "autonomous engineering".

## The trap to avoid

The word *agent* gets used to mean two incompatible things:

1. **Decision-maker** — an LLM "decides" whether a task can advance, who claims it, whether a feature is approved, what the next step is.
2. **Worker** — an LLM does the code work *inside* a task whose lifecycle is governed by deterministic rules.

Our product is the second. The first is the trap.

Buyers (enterprise delivery teams, regulated orgs, anyone shipping to production) pay for **predictability**: that the same task hits the same gates in the same order every time, with auditable state and reproducible review. The moment an LLM gets to "interpret" whether T3 can move to `in_review`, that promise breaks — and the system loses the only thing it has that an LLM-in-a-loop does not.

Whenever you feel the pull to "just let the agent handle it" at a workflow boundary, stop. That pull comes from the surface (LLMs feel magical) and ignores the spine (rules are what make the system saleable).

## The four layers

The product is a layered system. Each layer has a different operating principle and a different rate of change. Confusing them is the most common architectural mistake we can make.

| Layer | What it is | Operating principle |
|---|---|---|
| **Rules** | Lifecycle FSM, status transitions, dependency unblocking, claim protocol, file-scope rule, branch protocol, rebase rules, gate semantics | Deterministic code. No LLM in the loop. Changes via versioned feature work, never at runtime. |
| **Skills** | `start-implementation`, `pr-create`, `approve-feature`, `init-feature`, `respond-to-review`, … | Procedural, scriptable, side-effect-explicit. Skills *execute* rules; they do not negotiate them. |
| **Agents** | Claude Code sessions inside the executor; reviewer agents; future fix agents and design agents | Non-deterministic workers. Bounded to one task each. Read freely; mutate only via skills and MCP tools. |
| **Humans** | Product owner, tech lead, reviewer | Gates. Approvals and stage transitions are theirs. Agents prepare work; humans accept or reject it. |

**Rules are code. Skills are tools. Agents are workers. Humans are gates.** All four exist. None replaces another.

## Why this framing matters

It tells us what to *not* agentify: lifecycle, gates, claims, dependencies, file scope, branch hygiene. These are the spine.

It tells us where to *aggressively* agentify: anything that happens inside a single task — code, design, review, QA, doc drafting, refactor proposals. These are the bicep.

It gives a one-sentence pitch that survives technical scrutiny: **"AI does the work, rules run the process, humans hold the gates."** No buzzword salad, no claims the system cannot keep.

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
4. Does it add a new gate for a human? → fine, but ask whether the gate is load-bearing or ceremonial.
5. Does the marketing copy say "autonomous"? → rewrite.
