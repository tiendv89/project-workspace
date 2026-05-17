# Technical Design

## Feature
- Feature ID: `executor-capability`
- Title: Executor Capability — Full parity for alternative executors (impl + review)

## Current State

The Hermes executor (`runtime/executors/hermes/`) handles `kind=impl` tasks only.
There is no executor capability registry — the orchestrator has no way to know which
task kinds a given executor supports. All `kind=review` tasks are implicitly routed
to Claude regardless of `execution.runtime`.

## Constraints

- The orchestrator ABI contract must not change.
- The Hermes review executor must produce the same `result.json` schema as the Claude
  reviewer.
- Layer 1 recovery (`try/finally`) must fire for review tasks just as for impl tasks.
- Capability declaration must be statically readable — no runtime negotiation with
  the executor process.

## Options Considered

### Option A — Capability declared in executor profile config
Each executor profile in the runtime registry includes a `capabilities: [impl, review]`
list. The orchestrator reads this before dispatch.

- Pros: static, no ABI change, easy to extend
- Cons: registry schema needs to be defined and versioned

### Option B — Capability inferred from executor binary flags
The orchestrator probes the executor binary (`hermes-executor --capabilities`) before
each dispatch.

- Pros: self-describing executors
- Cons: adds a probe round-trip per dispatch, complicates the ABI

## Chosen Design

Option A. Capability is declared statically in the executor profile config. The
orchestrator reads `capabilities` at startup (or per-dispatch from a cached registry)
and matches it against the task's `kind` field before routing.

## Dependency Analysis

- Depends on `adding-hermes-executor` (done) for the base executor structure and
  ABI wiring.
- Coordinates with `agent-runtime-selector` on the registry schema — the selector
  reads `execution.runtime`; this feature adds `capabilities` to the same registry
  entry.

## Parallelization / Blocking Analysis

- Task breakdown and registry schema design can proceed in parallel with
  `agent-runtime-selector` design work.
- The Hermes review executor implementation is blocked until `adding-hermes-executor`
  is `done`.
