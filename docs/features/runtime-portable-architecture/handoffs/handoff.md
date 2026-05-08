# Handoff — runtime-portable-architecture

**Feature:** Portable runtime architecture — extract today's bundled orchestrator/executor into ports, adapters, and profiles  
**Completed:** 2026-05-09  
**All tasks:** T1–T10, all `done`, all implementation PRs merged to `tiendv89/agent-workflow`

---

## What was built

The orchestrator/executor was refactored from a bundled, tightly-coupled system into a ports-and-adapters (hexagonal) architecture with two concrete runtime profiles.

| Wave | Tasks | Deliverable |
|---|---|---|
| 1 | T1 | Port interfaces, types, and fake adapters |
| 2 | T2, T4 | `local-subprocess` profile wired; runner wrapper script (D6c) |
| 3 | T3, T5, T6 | `CompletionBrokerPort`, `InMemoryBrokerAdapter`, HTTP receiver, async submit/reap, shared reap loop |
| 4 | T7 | Redis-backed broker service (Go) + container |
| 5 | T8, T9, T10 | `DockerRunAdapter`, docker-compose bridge network, portability spec doc, fake-orchestrator harness, `CLAUDE.md` updates |

## Key architectural decisions

- **Hexagonal split (D1b):** orchestrator core depends only on typed TypeScript interfaces; adapters injected at startup
- **Async submit/reap (D2b):** executor submission is non-blocking; reap loop picks up completions asynchronously
- **Runtime-selected profiles (D4b):** `local-subprocess` and `local-docker` selected at startup via config — no bundled-image assumption
- **Nonce-only auth (D5a):** completion receiver authenticated by nonce only (no TLS in local profiles)
- **Shared completion broker (D7b):** single broker instance shared across submit and reap paths

## Authoritative references

- **Portability spec:** `runtime/portability-spec.md` in `agent-workflow` — every port, adapter, profile, runner env contract, broker protocol, and how to add a new profile
- **ABI spec:** `runtime/abi/docs/abi-spec.md` — executor-facing inputs, outputs, side-effects, lifecycle, examples
- **Operator guide:** `runtime/orchestrator/docs/OPERATOR-GUIDE.md` — deployment, Docker Compose entry point, env vars, common issues

## Operational notes

### Orchestrator GitHub account
The orchestrator needs a dedicated GitHub machine (bot) account for production. Each customer must invite it to their workspace repo with write/merge permissions. A personal token is not viable at scale. Revisit with a GitHub App installation per tenant when multi-tenancy auth is designed.

### Reap loop throughput
`runReapLoop` dispatches up to 10 completions per cycle sequentially. Safe under peek-and-lock (30s visibility timeout), but sequential dispatch means a slow item blocks the rest. Consider parallel dispatch if throughput becomes a bottleneck.

## Implementation PRs (agent-workflow repo)

All merged. Last task PR: https://github.com/tiendv89/agent-workflow/pull/75 (T10)

---

*Prepared for human handoff review. No deferred work — all scope delivered.*
