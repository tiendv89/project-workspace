# Technical Design

## Feature
- Feature ID: `adding-hermes-executor`
- Title: Hermes Executor — Workspace-aware agent cluster as a second executor

## Current state

The runtime has one executor: `runtime/executors/claude/`. The orchestrator spawns it
via `SubProcessAdapter`, which implements `ExecutorPort` by forking a child process.
The ABI is well-defined (`runtime/abi/docs/abi-spec.md`): env vars in, `result.json`
out, callback to the broker on completion.

There is no workspace knowledge accumulation between task runs. Every Claude executor
starts from the briefing alone.

## Constraints

- The orchestrator ABI contract (`ExecutorPort`, `ExecutorInput`, `ExecutorResult`,
  callback protocol) must not change.
- Hermes is used as-is via its published CLI — no fork, no internal modification.
- `result.json` must be written regardless of memory system availability.
- Parallel tasks for the same workspace must not conflict on any shared state.
- The orchestrator must remain blind to Hermes internals.

## Components

### 1. Hermes executor profile — `SubProcessAdapter` wiring

No new adapter class is required. The existing `SubProcessAdapter` is wired with the
Hermes executor binary as `executorBinPath`. Hermes-specific env vars are injected via
`extraEnv`. This is the same pattern as the Claude executor local-subprocess profile.

```typescript
// runtime/orchestrator/src/adapters/index.ts  (hermes-subprocess profile)

const hermesAdapter = new SubProcessAdapter({
  executorBinPath: path.join(config.hermesExecutorDist, "index.js"),
  extraEnv: {
    HERMES_INFERENCE_MODEL:   config.hermesModel,       // e.g. "deepseek-v4-flash"
    HERMES_INFERENCE_PROVIDER: config.hermesProvider,   // e.g. "deepseek"
    DEEPSEEK_API_KEY:          config.deepseekApiKey,
    ...(config.mem0Url             ? { MEM0_URL:                   config.mem0Url }             : {}),
    ...(config.mem0ApiKey          ? { MEM0_API_KEY:               config.mem0ApiKey }          : {}),
    ...(config.ragMcpUrl           ? { RAG_MCP_URL:                config.ragMcpUrl }           : {}),
    ...(config.ragMcpToken         ? { RAG_MCP_TOKEN:              config.ragMcpToken }         : {}),
    ...(config.hermesMemoryQueuePath ? { HERMES_MEMORY_QUEUE_PATH: config.hermesMemoryQueuePath } : {}),
    ...(config.hermesMaxTurns      ? { HERMES_MAX_TURNS:           String(config.hermesMaxTurns) } : {}),
  },
});
```

The orchestrator core sees only `ExecutorPort` — no Hermes internals, no model
credentials, no Mem0 config. All Hermes-specific wiring stays in the profile adapter.

The Hermes cluster controller (HTTP service, model registry, container spawning) is
deferred to `hermes-cluster-controller`. When that feature ships, `HermesClusterAdapter`
will replace the `SubProcessAdapter` wiring in the cluster profile.

### 2. Hermes Executor package (`runtime/executors/hermes/`)

Mirrors the structure of `runtime/executors/claude/`. The entrypoint is
`src/index.ts`, compiled to `dist/index.js`.

#### Startup sequence

```
Phase 1 — Management repo (identical to Claude executor ABI spec)
  mgmt_dir = ${EXECUTOR_WORKDIR}/mgmt
  clone_or_pull(MGMT_REPO_URL, mgmt_dir, "main")
  WORKSPACE_ROOT = mgmt_dir

Phase 2 — Implementation repo (identical to Claude executor ABI spec)
  impl_dir = ${EXECUTOR_WORKDIR}/impl
  clone_or_pull(TASK_REPO_URL, impl_dir, TASK_REPO_BRANCH)
  TASK_REPO_PATH = impl_dir

Phase 3 — Hermes home
  hermes_home = ${EXECUTOR_WORKDIR}/hermes-home
  mkdir hermes_home
  write hermes_home/config.yaml:
    model:
      provider: ${HERMES_PROVIDER}
      default: ${HERMES_MODEL}
    memory:
      provider: mem0
      url: ${MEM0_URL}        # omit section if MEM0_URL absent
      api_key: ${MEM0_API_KEY}
    mcp_servers:
      rag:
        url: ${RAG_MCP_URL}   # omit if RAG_MCP_URL absent
        headers:
          Authorization: "Bearer ${RAG_MCP_TOKEN}"
  HERMES_HOME = hermes_home

Phase 4 — Self-briefing (identical to Claude executor ABI spec)
  task_yaml = read(WORKSPACE_ROOT/docs/features/FEATURE_ID/tasks/TASK_ID.yaml)
  tasks_md  = read(WORKSPACE_ROOT/docs/features/FEATURE_ID/tasks.md)
  tech_md   = read(WORKSPACE_ROOT/docs/features/FEATURE_ID/technical-design.md)
  briefing  = build_briefing(task_yaml, tasks_md, tech_md)

Phase 5 — Execute (try/finally for Layer 1 recovery)
  try:
    spawn: hermes chat --query "$briefing" --quiet --ignore-rules
    env:   HERMES_HOME, HERMES_INFERENCE_MODEL, HERMES_INFERENCE_PROVIDER,
           HERMES_MAX_ITERATIONS, HERMES_YOLO_MODE=1
    cwd:   TASK_REPO_PATH
    wait for exit
    (Hermes exits after saving file changes — it does not commit, push, or open a PR)

  finally:
    runRecovery()   ← fires on abnormal exit; see Layer 1 recovery below

Phase 6 — Post-execution workflow protocol (wrapper, not Hermes)
  // Hermes is done. The wrapper now owns all workflow mechanics.
  git -C TASK_REPO_PATH add -A
  git -C TASK_REPO_PATH commit -m "feat(TASK_ID): <summary from briefing>"
  git -C TASK_REPO_PATH push origin TASK_REPO_BRANCH
  pr_url = curl pr-create logic (same as Claude executor):
    title: "feat(FEATURE_ID/TASK_ID): <description>"
    base:  TASK_BASE_BRANCH
    head:  TASK_REPO_BRANCH
  write RESULT_PATH:
    { "terminal_status": "in_review", "pr_url": pr_url }

Phase 7 — Memory capture (best-effort, non-blocking)
  candidates = extract_observations_from_hermes_output()
  if candidates not empty and HERMES_MEMORY_QUEUE_PATH set:
    write memory-candidates.json to HERMES_MEMORY_QUEUE_PATH
    (wrapped in try/catch — failure is logged and ignored)

Phase 8 — Exit
  exit 0
```

#### Briefing format

The briefing passed to `--query` is scoped to the code work only. The wrapper owns all
workflow protocol (git, PR, `result.json`); Hermes must not attempt any of those.

```
## Workspace context
You are an autonomous coding agent working on workspace {WORKSPACE_ID}.
Your working directory is {TASK_REPO_PATH}.

## Task
{task_yaml content}

## Description and subtasks
{tasks_md section for TASK_ID}

## Technical design
{technical-design.md content}

## Your scope
Make the required code changes and save the files. Do not commit, push, open a pull
request, or write any result file — those steps are handled outside your session.
When your changes are saved, you are done.
```

The briefing does not include git instructions, `result.json` schema, or PR format.
Hermes has no knowledge of `pr-create`, `RESULT_PATH`, or workflow conventions — the
wrapper handles all of that after Hermes exits.

Hermes inherits workspace Mem0 knowledge automatically at session start — the briefing
does not need to re-state what Mem0 already provides.

#### Layer 1 recovery (`src/recovery.ts`)

Fires in the `finally` block of Phase 5 — runs on any exit from `hermes chat`, normal
or abnormal. Mirrors `runtime/executors/claude/src/recovery.ts`:

1. No-op if valid `result.json` with `terminal_status: "in_review"` already exists
   (Phase 6 completed successfully — nothing to do)
2. Commit dirty tree in `TASK_REPO_PATH` as `wip(TASK_ID): incomplete — agent terminated`
3. Push (best-effort)
4. Find or open draft PR via GitHub REST API
5. Write `handover.md` next to `result.json`
6. Write `result.json` with `terminal_status: "blocked"`, `blocked_reason`, `pr_url`, `handover_path`

Non-throwing: each step wrapped in `try/catch`. Always produces a `result.json`.

Note: on a normal Hermes exit, Phase 6 (post-execution wrapper) runs before recovery
checks and writes `result.json` with `terminal_status: "in_review"`. Recovery then
short-circuits at step 1. Recovery only does real work when Hermes exits abnormally
before Phase 6 completes.

### 4. Memory consolidator service

An optional service within the Hermes cluster. Not required for executor correctness.

**Responsibilities:**
- Watch `HERMES_MEMORY_QUEUE_PATH` directory for incoming `memory-candidates.json` files
- For each file: parse workspace_id + observations, write to the workspace's Mem0 instance
- Delete file after successful write
- On Mem0 failure: retry with exponential backoff up to N times, then dead-letter

**`memory-candidates.json` schema:**
```json
{
  "workspace_id": "string",
  "task_id": "string",
  "handle": "string",
  "observed_at": "ISO-8601",
  "observations": [
    "string"
  ]
}
```

Observations are plain-language strings the executor extracted from its work —
non-obvious facts about the workspace that would help future executors. Examples:
- "Proto files are regenerated with `buf generate`, not `protoc` directly"
- "Database migrations use goose, not golang-migrate"
- "The `internal/auth` package owns all JWT validation; do not duplicate it"

**Isolation:** one Mem0 namespace per `workspace_id`. The consolidator routes each
file to the correct namespace by `workspace_id`. Cross-workspace contamination is
structurally impossible.

### 5. Mem0 instance (per workspace)

An external Mem0 service (self-hosted or Mem0 cloud) with one namespace per workspace.
Hermes connects to it via the memory provider config in `HERMES_HOME/config.yaml`.

**At executor session start:** Hermes queries Mem0 for context relevant to the current
task and injects it into the conversation. This is handled by Hermes's memory provider
system — no executor code required.

**Optional:** if `MEM0_URL` is absent from the cluster controller's config for a
workspace, the executor omits the memory section from `config.yaml`. Hermes runs
without a memory provider — stateless, no errors.

## Options considered

### Option A: Executor writes directly to Mem0 at exit
- Pro: simple, no consolidator service
- Con: Mem0 write is on the critical path to `exit 0`; a slow or failed Mem0 blocks
  the executor and risks losing `result.json` (if recovery doesn't fire in time)
- **Rejected** — memory must never block executor exit

### Option B: PVC per executor for HERMES_HOME persistence
- Pro: Hermes session history survives container restarts, richer retry continuity
- Con: PVC provisioning + lifecycle management adds cluster controller complexity;
  SQLite on a PVC is safe but retry continuity is already handled by Layer 1/2/3
  (handover.md); PVCs add cost for state that is intentionally disposable
- **Rejected** — ephemeral tmpdir is sufficient; Layer 1/2/3 handles continuity

### Option C: Shared workspace-level HERMES_HOME on EFS
- Pro: all executors for a workspace share one Hermes session history
- Con: SQLite concurrent writes from parallel executors → locking contention;
  serialises parallel task execution; expensive
- **Rejected** — Mem0 is the correct shared layer; SQLite must stay per-executor

### Option D: Linearisation layer above SQLite
- Pro: enables shared SQLite without corruption
- Con: SQLite's POSIX locking is below the layer we can intercept without modifying
  Hermes; adds complexity for no benefit over Mem0-based sharing
- **Rejected** — wrong layer; Mem0 solves the sharing requirement cleanly

### Chosen design

Ephemeral executor container + ephemeral `HERMES_HOME` (tmpdir) + workspace-scoped
Mem0 + optional memory consolidator. Each component has a single responsibility;
failure of any optional component degrades gracefully without affecting task execution.

## Data flow summary

```
Orchestrator
  → SubProcessAdapter.submit(input)
  → forks Hermes executor process (extraEnv: model, api_key, mem0, ...)

Hermes executor process
  → Phase 1/2: clone repos
  → Phase 3: write HERMES_HOME/config.yaml (Mem0 + MCP)
  → Phase 4: build briefing from mgmt clone
  → Phase 5: hermes chat (loads Mem0 at session start; saves file changes only)
  → Phase 6: wrapper commits + pushes + opens impl PR + writes result.json
  → Phase 7: write memory-candidates.json (best-effort)
  → exit 0

SubProcessAdapter
  → detects result.json
  → POST callback to broker (orchestrator reap loop picks it up)

Memory consolidator (optional, separate process)
  → watches HERMES_MEMORY_QUEUE_PATH
  → drains memory-candidates.json → Mem0

Orchestrator reap loop
  → reads ExecutorResult from broker
  → updates task YAML, records pr_url
  → calls ack()
```

## Dependency analysis

| Dependency | Status | Notes |
|---|---|---|
| `agent-runtime-split` | done | ABI contract, ExecutorPort interface, SubProcessAdapter pattern |
| `runtime/abi/src/types.ts` | done | ExecutorInput, ExecutorResult — no changes needed |
| Hermes CLI | external | `hermes` binary must be on PATH in executor process |
| Mem0 | external, optional | Self-hosted or cloud; absent = graceful degradation |
| RAG MCP server | external, optional | Already in platform; absent = no RAG tools |
| `hermes-cluster-controller` | future | HTTP service, model registry, container spawning — not a dependency of this feature |

## Parallelisation / blocking analysis

- **T1 (SubProcessAdapter profile wiring)** — unblocked; thin config change alongside existing adapter
- **T2 (Executor package + briefing + Layer 1)** — unblocked; depends only on ABI spec
- **T3 (Memory consolidator + Mem0 config)** — depends on T2 (memory-candidates.json schema)
- **T4 (Tests + integration)** — depends on T1 and T2

T1 and T2 can be implemented in parallel. T3 can start once T2 is done. T4 gates on T1 + T2.

Note: the cluster controller (container spawning, model registry, HTTP service) is
deferred to `hermes-cluster-controller` and is not in scope here.
