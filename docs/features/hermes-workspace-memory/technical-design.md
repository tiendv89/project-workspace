# Technical Design

## Feature
- Feature ID: `hermes-workspace-memory`
- Title: Hermes Workspace Memory — Persistent knowledge accumulation via Mem0

## Current state

The Hermes executor (`runtime/executors/hermes/`) delivered by `adding-hermes-executor`
runs stateless. `HERMES_HOME/config.yaml` contains only model and MCP configuration —
no Mem0 stanza. The executor produces one output file (`result.json`) and exits.
Workspace knowledge discovered during a run is discarded at process exit.

The memory hook points are already scaffolded in the executor startup sequence:
- **Phase 3** writes `HERMES_HOME/config.yaml` — the Mem0 stanza is intentionally
  omitted until this feature ships.
- **Phase 7** (memory capture) does not exist yet — this feature adds it.

## Constraints

- Memory must never block `result.json`. All memory writes are best-effort, wrapped
  in `try/catch`, logged on failure, and ignored.
- The ABI contract does not change. Memory env vars (`MEM0_URL`, `MEM0_API_KEY`,
  `HERMES_MEMORY_QUEUE_PATH`) arrive via `SubProcessAdapterOpts.extraEnv`; the
  orchestrator core is unaware of them.
- Parallel executors for the same workspace must not conflict on shared memory state.
  Each executor has its own ephemeral `HERMES_HOME` — isolation is structural.
- The executor must degrade gracefully when Mem0 is absent: omit the memory stanza
  from `config.yaml`, skip Phase 7, exit normally.
- The consolidator is optional. Its absence must not cause executor failures.

## Options considered

### Option A — Executor writes directly to Mem0 at exit

After Phase 6, the executor connects to Mem0 and writes observations directly.

- Pro: simple — no consolidator service, no queue file
- Con: Mem0 write is on the critical path to `exit 0`. A slow or failed Mem0
  connection blocks the executor and risks delaying `result.json` delivery. If the
  executor process is killed before the write completes, observations are lost without
  a recoverable artifact.
- **Rejected** — memory must never block executor exit.

### Option B — PVC per executor for `HERMES_HOME` persistence

Provision a PVC per executor handle; mount it at `HERMES_HOME`.

- Pro: Hermes session history (SQLite) survives container restarts; richer retry
  continuity for abnormal exits.
- Con: PVC provisioning and lifecycle management adds cluster controller complexity;
  SQLite on a shared PVC risks locking under parallel access; Layer 1/2/3 recovery
  (handover.md) already handles continuity without needing session history; PVCs add
  cost for state that is intentionally disposable.
- **Rejected** — ephemeral tmpdir is sufficient; Layer 1/2/3 handles continuity.

### Option C — Shared workspace-level `HERMES_HOME` on EFS

All executors for the same workspace share one `HERMES_HOME` on a shared filesystem.

- Pro: cross-executor Hermes session history without Mem0.
- Con: SQLite concurrent writes from parallel executors → locking contention;
  serialises parallel task execution; expensive EFS provisioning; does not replace
  Mem0 for structured, queryable workspace knowledge.
- **Rejected** — Mem0 is the correct shared layer; SQLite must stay per-executor.

### Option D — Linearisation layer above SQLite

Intercept SQLite writes to allow shared access without corruption.

- Pro: enables shared SQLite without locking.
- Con: SQLite's POSIX locking operates below any layer we can intercept without
  forking Hermes; adds complexity for no benefit over Mem0-based sharing.
- **Rejected** — wrong abstraction layer; Mem0 solves the requirement cleanly.

### Chosen design

Ephemeral executor + ephemeral `HERMES_HOME` + workspace-scoped Mem0 + optional
memory consolidator. The executor writes observations to a queue file (`memory-candidates.json`)
as a best-effort, non-blocking step after `result.json` is written. A separate
consolidator service drains the queue into Mem0. Each component has a single
responsibility; failure of any optional component degrades gracefully.

## Components

### 1. Phase 3 extension — Mem0 stanza in `HERMES_HOME/config.yaml`

When `MEM0_URL` is present in the executor's env, the wrapper adds a `memory_provider`
block to `HERMES_HOME/config.yaml` before spawning `hermes chat`. Hermes reads this
config at startup and connects to Mem0 to load workspace knowledge into context.

```yaml
# HERMES_HOME/config.yaml (with Mem0 enabled)
model:
  provider: ${HERMES_INFERENCE_PROVIDER}
  default:  ${HERMES_INFERENCE_MODEL}
memory:
  provider: mem0
  url:      ${MEM0_URL}
  api_key:  ${MEM0_API_KEY}
mcp_servers:
  rag:
    url: ${RAG_MCP_URL}
    headers:
      Authorization: "Bearer ${RAG_MCP_TOKEN}"
```

When `MEM0_URL` is absent, the `memory:` stanza is omitted entirely. Hermes runs
without a memory provider — stateless, no errors.

This change is a conditional branch inside the existing Phase 3 of `src/index.ts` in
`runtime/executors/hermes/`. No new file; one additional `if (config.mem0Url)` block.

### 2. Phase 7 — Memory capture (`src/memory.ts`)

Added after Phase 6 (after `result.json` is written). Entirely wrapped in `try/catch`.

```
Phase 7 — Memory capture (best-effort, non-blocking)
  if HERMES_MEMORY_QUEUE_PATH not set → skip silently
  candidates = extractObservations(hermesSessionOutput)
  if candidates is empty → skip
  write memory-candidates.json to HERMES_MEMORY_QUEUE_PATH:
    {
      "workspace_id": WORKSPACE_ID,
      "task_id":      TASK_ID,
      "handle":       HANDLE,
      "observed_at":  ISO-8601 now,
      "observations": [ "string", ... ]
    }
  on any error → log warning, continue to exit 0
```

`extractObservations` parses the Hermes session transcript for non-obvious workspace
facts. Examples of what gets captured:
- "Proto files are regenerated with `buf generate`, not `protoc` directly"
- "Database migrations use goose, not golang-migrate"
- "The `internal/auth` package owns all JWT validation; do not duplicate it"

Observations are plain-language strings — not structured key-value data. Mem0 handles
semantic indexing and retrieval.

### 3. Memory consolidator service (`runtime/services/memory-consolidator/`)

An optional standalone service. Not required for executor correctness.

**Responsibilities:**
- Watch `HERMES_MEMORY_QUEUE_PATH` directory for incoming `memory-candidates.json` files
- For each file: parse `workspace_id` + `observations`, write to the correct Mem0 namespace
- Delete the file after successful write
- On Mem0 failure: retry with exponential backoff up to N times, then dead-letter

**Isolation:** one Mem0 namespace per `workspace_id`. The consolidator routes each
file to the correct namespace by `workspace_id`. Cross-workspace contamination is
structurally impossible.

**`memory-candidates.json` schema:**
```json
{
  "workspace_id": "string",
  "task_id": "string",
  "handle": "string",
  "observed_at": "ISO-8601",
  "observations": ["string"]
}
```

### 4. Mem0 instance (per workspace)

An external Mem0 service (self-hosted or Mem0 cloud) with one namespace per workspace.
Hermes connects via `HERMES_HOME/config.yaml` at session start.

**At executor session start:** Hermes queries Mem0 for context relevant to the current
task and injects it automatically. This is handled by Hermes's memory provider system —
no additional executor code required.

**Optional:** when `MEM0_URL` is absent, the executor omits the memory stanza and
runs stateless. No error.

## Data flow

```
Orchestrator
  → SubProcessAdapter.submit(input)
  → forks Hermes executor process
    (extraEnv: ..., MEM0_URL, MEM0_API_KEY, HERMES_MEMORY_QUEUE_PATH)

Hermes executor process
  → Phase 1/2: clone repos
  → Phase 3: write HERMES_HOME/config.yaml (model + Mem0 stanza + MCP)
  → Phase 4: build briefing from mgmt clone
  → Phase 5: hermes chat
      Hermes loads Mem0 at session start → inherits workspace knowledge
      Hermes saves file changes only
  → Phase 6: wrapper commits + pushes + opens impl PR + writes result.json
  → Phase 7: write memory-candidates.json (best-effort, non-blocking)
  → exit 0

Memory consolidator (optional, separate process)
  → watches HERMES_MEMORY_QUEUE_PATH
  → drains memory-candidates.json → Mem0 (workspace namespace)
  → if absent → queue files accumulate until consolidator is deployed

Mem0 instance (per workspace, optional)
  → if absent → stateless execution, no accumulation

SubProcessAdapter
  → detects result.json (independent of memory path)
  → POST callback to broker

Orchestrator reap loop
  → reads ExecutorResult from broker
  → updates task YAML, records pr_url
  → calls ack()
```

## Dependency analysis

| Dependency | Status | Notes |
|---|---|---|
| `adding-hermes-executor` | prerequisite | Phase 3 hook and executor package must exist before this feature can extend them |
| Hermes CLI | external | Must support `memory.provider: mem0` in `config.yaml` — verify against Hermes docs |
| Mem0 | external, optional | Self-hosted or Mem0 cloud; absent = graceful stateless degradation |
| `hermes-cluster-controller` | future | Workspace-to-Mem0 registry and config management; this feature wires Mem0 directly via env vars until that ships |

## Parallelization / blocking analysis

```
T1: Phase 3 Mem0 stanza + Phase 7 memory capture (runtime/executors/hermes)
  └── BLOCKED on adding-hermes-executor done
      (extends existing Phase 3 in src/index.ts; Phase 7 is a new step in same file)

T2: Memory consolidator service (runtime/services/memory-consolidator)
  └── BLOCKED on T1 (memory-candidates.json schema defined in Phase 7 implementation)

T3: Tests + integration
  └── BLOCKED on T1 (executor memory path must exist to test end-to-end)
  └── BLOCKED on T2 (consolidator must exist to test full drain cycle)
  │
  T1 → T2 and T3 in sequence; T2 and T3 can overlap once T1 is done
```

## Repository impact

| Repo | Changes |
|---|---|
| `runtime/executors/hermes` | Extend `src/index.ts` Phase 3 (Mem0 stanza); add `src/memory.ts` (Phase 7); add env var reads for `MEM0_URL`, `MEM0_API_KEY`, `HERMES_MEMORY_QUEUE_PATH` |
| `runtime/services/memory-consolidator` | New service: file watcher, Mem0 writer, retry logic |

## Validation and release impact

- Unit test: `extractObservations` with a sample Hermes transcript; verify correct
  `memory-candidates.json` output.
- Integration test (with Mem0): spawn executor with `MEM0_URL` set; verify a second
  executor for the same workspace inherits observations from the first.
- Degradation test (no Mem0): spawn executor without `MEM0_URL`; verify `result.json`
  is written normally, no errors logged.
- Consolidator test: write a `memory-candidates.json` to the queue dir; verify
  consolidator drains it to Mem0 and deletes the file.
- No ABI changes → no orchestrator migration needed.
- Rollout: Phase 3 Mem0 stanza is conditional on `MEM0_URL` — safe to deploy without
  a Mem0 instance. Operators enable memory per workspace by adding `MEM0_URL` to
  `extraEnv`.
