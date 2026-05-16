# Product Specification

## Feature
- Feature ID: `hermes-workspace-memory`
- Title: Hermes Workspace Memory — Persistent knowledge accumulation via Mem0

## Problem

The Hermes executor introduced by `adding-hermes-executor` runs stateless by default.
Each task starts from the briefing and codebase alone — codebase conventions, team
patterns, and architectural decisions discovered in one run are lost by the next.

This is the same statelessness problem Claude has today, and it was the original
motivation for choosing Hermes (which has a pluggable memory provider system). Without
this feature, the "workspace-aware" promise of Hermes is not delivered.

## Goals

1. **Workspace-scoped Mem0 for persistent knowledge** — each workspace has a
   dedicated Mem0 instance (or namespace). At session start, Hermes loads the
   workspace's accumulated knowledge from Mem0 — codebase conventions, team patterns,
   known architectural facts. This knowledge is inherited by every Hermes executor
   that runs against the workspace, regardless of which task it is executing.

2. **Knowledge capture via `memory-candidates.json`** — when the executor finishes,
   it writes a structured file of new observations alongside `result.json`. This file
   is the executor's only output to the memory system. The executor never writes
   directly to Mem0.

3. **Memory consolidator service (optional)** — a separate service within the Hermes
   cluster watches the memory queue and drains `memory-candidates.json` files into
   Mem0. If the consolidator is not deployed, execution degrades gracefully to
   stateless — no memory accumulation, no failures.

4. **Memory never blocks executor exit** — `result.json` is the executor's critical
   output. Memory capture is best-effort and entirely decoupled: the executor exits
   after writing `result.json`, regardless of memory system state. A failure writing
   `memory-candidates.json` is logged and ignored.

5. **Graceful stateless degradation** — if Mem0 and the consolidator are absent, the
   executor completes normally with no errors. Memory is an opt-in enhancement, not a
   hard dependency.

## Non-goals

- **Hermes executor wiring** — handled by `adding-hermes-executor` (prerequisite).
- **Multi-workspace Mem0 registry** — workspace-to-Mem0 mapping and the config registry
  are `hermes-cluster-controller` scope.
- **SQLite coordination across executors** — each executor has its own SQLite in its
  ephemeral `HERMES_HOME`. No sharing, no locking required.
- **PVC per executor** — not needed. Mem0 holds the persistent layer; the process is
  intentionally ephemeral.

## Knowledge lifecycle

```
Prior executor runs for workspace W
    → wrote observations to memory-candidates.json
    → consolidator drained to Mem0 (workspace W namespace)

New executor for workspace W, task T3
    → Hermes loads Mem0 at session start
    → inherits: "auth in /internal/auth", "table-driven tests", "goose migrations"
    → works with that context
    → discovers new observation: "proto files regenerated with buf, not protoc"
    → writes to memory-candidates.json at exit

Consolidator
    → drains memory-candidates.json → Mem0

Next executor for workspace W
    → inherits all of the above, including the new proto observation
```

## Two outputs, two consumers

The memory-enabled executor produces two output files with separate consumers and
separate failure modes:

| File | Consumer | Failure mode |
|---|---|---|
| `result.json` at `RESULT_PATH` | Orchestrator (via callback) | Task blocked — must not fail |
| `memory-candidates.json` at `HERMES_MEMORY_QUEUE_PATH` | Memory consolidator | Observation lost — acceptable |

`result.json` is on the critical path. `memory-candidates.json` is best-effort.

## Additional environment variables

These extend the base Hermes executor env vars from `adding-hermes-executor`:

| Variable | Description |
|---|---|
| `MEM0_URL` | Mem0 instance URL for this workspace (optional) |
| `MEM0_API_KEY` | Mem0 auth token (optional) |
| `HERMES_MEMORY_QUEUE_PATH` | Path to write `memory-candidates.json` (optional) |

When `MEM0_URL` is absent, the executor runs stateless. When present, Hermes
loads workspace knowledge at session start and the wrapper writes
`memory-candidates.json` at exit.

## Dependencies

- `adding-hermes-executor` — must be `done`. This feature extends the executor;
  it does not replace it.

## Success criteria

- A second executor for the same workspace inherits observations written by the first
  (when the consolidator is running).
- If Mem0 and the consolidator are absent, the executor completes normally with no
  errors — stateless degradation.
- A failure writing `memory-candidates.json` does not affect `result.json` or task outcome.
