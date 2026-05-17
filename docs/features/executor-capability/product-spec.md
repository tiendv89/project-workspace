# Product Specification

## Feature
- Feature ID: `executor-capability`
- Title: Executor Capability — Full parity for alternative executors (impl + review)

## Problem

`adding-hermes-executor` delivers Hermes as a second executor but scopes it to
`kind=impl` tasks only. Review capability (`kind=review`) is deferred.

An executor that can only implement is not a true alternative to Claude — it cannot
close the loop on its own work. The orchestrator must still route all review tasks
back to Claude regardless of how cheap or fast the alternative executor is. This
creates a structural dependency on Claude for every feature, undermining the cost and
autonomy goals of the multi-executor architecture.

This feature closes that gap: it defines what "full capability" means for an executor,
and delivers review support for Hermes as the first instance of a fully capable
alternative executor.

## Goals

1. **Define the executor capability contract** — formalise what task kinds an executor
   must support to be considered fully capable: at minimum `kind=impl` and
   `kind=review`. Capability is declared per executor in the runtime registry so the
   orchestrator can route only to executors that support the required kind.

2. **Hermes review executor** — extend the Hermes executor to handle `kind=review`
   tasks. The review executor reads the impl PR diff, evaluates it against the task
   spec and technical design, posts an `APPROVE` or `REQUEST_CHANGES` GitHub review,
   and writes a valid reviewer `result.json`. The same ABI contract and Layer 1
   recovery apply.

3. **Review briefing for Hermes** — the wrapper builds a review-specific briefing:
   PR diff, task spec, technical design, and the reviewer rubric. Hermes is instructed
   to output structured review commentary only — no git operations, no file writes
   beyond the result. The wrapper posts the GitHub review and writes `result.json`.

4. **Capability-aware dispatch** — the orchestrator checks the target executor's
   declared capability before dispatch. If the executor does not support the required
   task kind, it falls back to the next capable executor in the profile chain (Claude
   as the guaranteed fallback).

5. **Parity validation** — a review task executed by Hermes must produce a result
   indistinguishable from a Claude reviewer result at the orchestrator boundary:
   same `result.json` schema, same GitHub review state, same PR transition logic.

## Non-goals

- **Auto-routing based on kind** — the orchestrator's runtime-selection logic is
  `agent-runtime-selector`'s scope. This feature only adds the capability declaration
  and the review executor implementation.
- **Other task kinds beyond impl and review** — no additional kinds are defined here.
- **Non-Hermes executors** — the capability contract is defined generically, but
  only the Hermes review executor is implemented in this feature. Other runtimes
  adopt the contract in their own features.
- **Review quality benchmarking** — comparative evaluation of Hermes vs Claude review
  quality is out of scope. Operators choose routing intentionally.

## Success criteria

- A `kind=review` task with `execution.runtime: hermes` runs end-to-end: PR diff
  fetched, review posted to GitHub (`APPROVE` or `REQUEST_CHANGES`), valid
  `result.json` written, orchestrator routes task state correctly.
- A `kind=review` task routed to an executor that does not declare review capability
  falls back to Claude without error.
- The Hermes review executor passes the same Layer 1 recovery contract as the impl
  executor: abnormal exit still produces a valid (blocked) `result.json`.
- No changes required to the orchestrator ABI contract.

## Dependencies

- `adding-hermes-executor` — must be `done` before this feature starts. The review
  executor is built on top of the impl executor's wrapper and ABI wiring.
- `agent-runtime-selector` — capability-aware dispatch requires the selector to read
  executor capability declarations. Coordination needed on the registry schema.
