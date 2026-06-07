# Technical Design

## Feature
- Feature ID: `go-orchestrator-parity`
- Title: Go Orchestrator — Autonomous Parity (Reviewer Cycle, Drift Daemon, Handoff Trigger)

> Phase 1 technical design has **not** started. This file is a stub — the tech lead produces it via the `tech-lead` skill only after `product-spec.md` is approved. Design must build on the `workflow-db` primitives (guarded-`UPDATE` claim, owner-partitioned broker, PR-merge poll, auto-ready) rather than reinventing them.

## Current State
To be written after product-spec approval. Establish the baseline delivered by `workflow-db`
(human-merge slice) and the TS-orchestrator reference loops being ported: `pr/handle-merged.ts`,
`task/dispatch-review-result.ts`, `feature/review-cycle.ts`, `feature/handoff-trigger.ts`,
`feature/lifecycle-manager.ts` (drift), `task/unblock-deps.ts`.

## Constraints
- Depends on `workflow-db` — reuse its write-path primitives; do not duplicate the claim/broker/merge-poll work.
- Preserve the single-owner-per-feature invariant and owner-partitioned broker coexistence.

## Options Considered
### Option A
- Pros:
- Cons:

### Option B
- Pros:
- Cons:

## Chosen Design
To be written.

## Dependency Analysis
Hard dependency on `workflow-db`. Document the cross-repo release ordering for any schema or
broker changes this feature adds on top.

## Parallelization / Blocking Analysis
To be written in Phase 1.
