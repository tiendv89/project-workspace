# Production Runbook Notes

Operational notes captured during implementation of the runtime portable architecture.
These should be incorporated into the final production runbook before go-live.

---

## Orchestrator GitHub Account

The orchestrator needs a dedicated GitHub machine (bot) account for production.

**Why:** The orchestrator merges implementation PRs on behalf of the platform. Each
customer must invite the bot account to their workspace repo as a collaborator with
merge permissions. Using a personal token is not viable at scale.

**Onboarding step:** Add a step in the customer onboarding runbook — invite the
platform bot account (e.g. `workflow-bot`) to the customer's workspace repo with
write/merge permissions before running the orchestrator against it.

**Future:** This is a temporary constraint. The proper solution is a GitHub App
installation per tenant with scoped tokens — revisit when the multi-tenancy auth
architecture is designed. Do not design workarounds assuming a personal token.

---

## Reap Loop Throughput

`runReapLoop` currently fetches up to 10 completions per cycle and dispatches them
sequentially. This is correct and safe under peek-and-lock (30s visibility timeout
protects against crash mid-batch), but sequential dispatch means a slow item blocks
the rest of the batch.

**Future:** Parallel dispatch per completion item if throughput becomes a bottleneck.
No action needed for initial production.
