# Technical Design

## Feature
- Feature ID: `hermes-workspace-memory`
- Title: Hermes Workspace Memory — Persistent knowledge accumulation via Mem0

## Current State

The Hermes executor (`runtime/executors/hermes/`) runs stateless. `HERMES_HOME/config.yaml`
is written at Phase 3 but contains only MCP configuration — no Mem0 stanza.
The wrapper does not write `memory-candidates.json`. Workspace knowledge is not
accumulated between runs.

## Constraints

- Memory must not block `result.json` — all memory writes are best-effort, wrapped
  in try/catch, and logged on failure.
- The ABI contract does not change. Memory env vars arrive via `extraEnv`; the
  orchestrator core is unaware of them.
- Parallel executors for the same workspace must not conflict on any shared memory
  state. Each executor has its own ephemeral `HERMES_HOME`.

## Chosen Design

### Phase 3 extension — Mem0 stanza in `HERMES_HOME/config.yaml`

When `MEM0_URL` is present, the wrapper adds a `memory_provider` block to
`HERMES_HOME/config.yaml` before spawning `hermes chat`. Hermes reads this config
at startup and connects to Mem0 to load workspace knowledge into context.

### Post-execution — `memory-candidates.json`

After `result.json` is written, the wrapper inspects Hermes session output for
structured observations and writes `memory-candidates.json` to
`HERMES_MEMORY_QUEUE_PATH`. Failure at this step is caught, logged, and ignored.

### Memory consolidator

A separate, optional service (`memory-consolidator/`) watches `HERMES_MEMORY_QUEUE_PATH`
and drains files into Mem0. The executor does not depend on it being present.

## Dependency Analysis

- Depends on `adding-hermes-executor` (done) for the base executor and Phase 3
  config-write hook.
- Coordinates with `hermes-cluster-controller` on the workspace-to-Mem0 registry
  schema when that feature is in design.

## Parallelization / Blocking Analysis

- Design and scaffolding can proceed once `adding-hermes-executor` is `done`.
- Consolidator service is independently deployable; its absence does not block
  executor work.
