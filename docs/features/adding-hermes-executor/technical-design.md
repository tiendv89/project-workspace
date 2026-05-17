# Technical Design

## Feature
- Feature ID: `adding-hermes-executor`
- Title: Hermes Executor — ABI-conformant executor image for Hermes Agent

## Current state

The runtime has one executor: `runtime/executors/claude/`. The orchestrator spawns it
via `SubProcessAdapter`, which implements `ExecutorPort` by forking a child process.
The ABI is well-defined (`runtime/abi/docs/abi-spec.md`): env vars in, `result.json`
out, callback to the broker on completion.

Every Claude executor starts stateless — no cross-run knowledge accumulation (that
is deferred to `hermes-workspace-memory`).

## Constraints

- The orchestrator ABI contract (`ExecutorPort`, `ExecutorInput`, `ExecutorResult`,
  callback protocol) must not change.
- Hermes is used as-is via its published CLI — no fork, no internal modification.
- `result.json` must always be written — Layer 1 recovery guarantees this.
- Parallel tasks for the same workspace must not conflict on any shared state.
- The orchestrator must remain blind to Hermes internals.
- Memory integration is out of scope — this executor runs stateless by default.

## Options considered

### Option A — New `HermesSubProcessAdapter` class

Create a dedicated adapter class that hard-codes Hermes-specific env injection and
startup logic.

- Pro: Hermes concerns are fully encapsulated in one class
- Con: duplicates `SubProcessAdapter` logic; requires a new `ExecutorPort` implementation
  to maintain; the only Hermes-specific logic is env vars and `executorBinPath` — not
  enough to justify a new class

### Option B — Reuse `SubProcessAdapter` with a Hermes executor profile (chosen)

Wire the existing `SubProcessAdapter` with `executorBinPath` pointing at the Hermes
executor binary. Hermes-specific config is passed as env vars — the executor reads
`process.env.HERMES_INFERENCE_MODEL`, `process.env.HERMES_INFERENCE_PROVIDER`, etc.
directly. The orchestrator sets those vars on the child process via `extraEnv`; it
never imports or calls into executor code. Env vars are the explicit, version-stable
boundary between the two codebases.

- Pro: zero new adapter code; same pattern as the Claude executor; env-var interface
  works identically whether the executor runs as a local subprocess or inside a
  container — the orchestrator just sets the env, the executor reads it
- Pro: `HermesClusterAdapter` replaces this profile in a single config swap when
  `hermes-cluster-controller` ships — no executor code changes required
- Con: none — env vars as the interface is the intended design

**Chosen: Option B.**

## Components

### 1. Hermes executor profile — `SubProcessAdapter` wiring

#### How the orchestrator chooses an adapter in this version

Two orthogonal concerns are configured independently:

- **`EXECUTOR_PROFILE`** — infrastructure topology: how the executor is spawned.
  Valid values: `local-subprocess` (default), `local-docker`. Determines the adapter class.
- **`EXECUTOR_TYPE`** — which agent runs. Valid values: `claude` (default), `hermes`.
  Determines the binary path and `extraEnv`.

In this version there is no per-task routing — selection is static at startup and
applies to all tasks dispatched by that orchestrator instance. Per-task routing
(`execution.runtime` on task YAMLs) is deferred to `agent-runtime-selector`.

```typescript
// runtime/orchestrator/src/adapters/index.ts

export function createExecutorAdapter(config: OrchestratorConfig): ExecutorPort {
  const profile      = process.env.EXECUTOR_PROFILE ?? 'local-subprocess';
  const executorType = process.env.EXECUTOR_TYPE    ?? 'claude';

  switch (profile) {
    case 'local-subprocess':
      return new SubProcessAdapter({
        executorBinPath: resolveExecutorBin(executorType, config),
        extraEnv:        resolveExecutorEnv(executorType, config),
      });

    // future: 'local-docker', 'cluster'
    default:
      throw new Error(`Unknown EXECUTOR_PROFILE: ${profile}`);
  }
}

function resolveExecutorBin(type: string, config: OrchestratorConfig): string {
  switch (type) {
    case 'hermes': return path.join(config.hermesExecutorDist, "index.js");
    case 'claude':
    default:       return path.join(config.claudeExecutorDist, "index.js");
  }
}

function resolveExecutorEnv(type: string, config: OrchestratorConfig): Record<string, string> {
  switch (type) {
    case 'hermes': return {
      HERMES_INFERENCE_MODEL:    config.hermesModel,
      HERMES_INFERENCE_PROVIDER: config.hermesProvider,
      DEEPSEEK_API_KEY:          config.deepseekApiKey,
      ...(config.ragMcpUrl    ? { RAG_MCP_URL:    config.ragMcpUrl }    : {}),
      ...(config.ragMcpToken  ? { RAG_MCP_TOKEN:  config.ragMcpToken }  : {}),
      ...(config.hermesMaxTurns ? { HERMES_MAX_TURNS: String(config.hermesMaxTurns) } : {}),
    };
    case 'claude':
    default: return { /* Claude-specific env vars */ };
  }
}
```

The orchestrator core receives only an `ExecutorPort` — no knowledge of profile or
executor type. Adding a new executor type (e.g. `gpt-4o`) is a new `case` in
`resolveExecutorBin` / `resolveExecutorEnv` only. Adding a new topology (e.g.
`local-docker`) is a new `case` in the profile switch only. The two axes never mix.

When `agent-runtime-selector` ships, `createExecutorAdapter` is replaced by per-task
dispatch that reads `task.execution.runtime` — the executor packages themselves are
unchanged.

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
      provider: ${HERMES_INFERENCE_PROVIDER}
      default: ${HERMES_INFERENCE_MODEL}
    mcp_servers:
      rag:
        url: ${RAG_MCP_URL}     # omit section if RAG_MCP_URL absent
        headers:
          Authorization: "Bearer ${RAG_MCP_TOKEN}"
  HERMES_HOME = hermes_home
  # No memory stanza — stateless by default. Mem0 config added by hermes-workspace-memory.

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
  git -C TASK_REPO_PATH add -A
  git -C TASK_REPO_PATH commit -m "feat(TASK_ID): <summary from briefing>"
  git -C TASK_REPO_PATH push origin TASK_REPO_BRANCH
  pr_url = curl pr-create logic (same as Claude executor):
    title: "feat(FEATURE_ID/TASK_ID): <description>"
    base:  TASK_BASE_BRANCH
    head:  TASK_REPO_BRANCH
  write RESULT_PATH:
    { "terminal_status": "in_review", "pr_url": pr_url }

Phase 7 — Exit
  exit 0
```

Note: Phase 7 (memory-candidates.json capture) is added by `hermes-workspace-memory`.
This executor produces only `result.json`.

#### Briefing format

The briefing passed to `--query` is scoped to code work only. The wrapper owns all
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

On a normal Hermes exit, Phase 6 writes `result.json` with `terminal_status: "in_review"`
before recovery checks. Recovery short-circuits at step 1. Recovery only does real work
on abnormal exits.

## Data flow

```
Orchestrator
  → SubProcessAdapter.submit(input)
  → forks Hermes executor process
    (extraEnv: HERMES_INFERENCE_MODEL, HERMES_INFERENCE_PROVIDER, DEEPSEEK_API_KEY, ...)

Hermes executor process
  → Phase 1/2: clone repos
  → Phase 3: write HERMES_HOME/config.yaml (model + MCP)
  → Phase 4: build briefing from mgmt clone
  → Phase 5: hermes chat (saves file changes only)
  → Phase 6: wrapper commits + pushes + opens impl PR + writes result.json
  → exit 0

SubProcessAdapter
  → detects result.json
  → POST callback to broker (orchestrator reap loop picks it up)

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
| RAG MCP server | external, optional | Already in platform; absent = no RAG tools |
| `hermes-cluster-controller` | future | HTTP service, model registry — not a dependency of this feature |
| `hermes-workspace-memory` | future | Mem0 + consolidator — this executor is stateless until that feature ships |

## Parallelization / blocking analysis

```
T1: SubProcessAdapter profile wiring (runtime/orchestrator)
  └── Can begin now — no blockers

T2: Hermes executor package — phases 1–6 + Layer 1 recovery (runtime/executors/hermes)
  └── Can begin now — no blockers
  │
  T1 and T2 run in parallel
  │
  T3: Tests + integration (runtime/executors/hermes + runtime/orchestrator)
      └── BLOCKED on T1 (adapter must be wired before end-to-end spawn test)
      └── BLOCKED on T2 (executor package must exist before it can be tested)
```

## Repository impact

| Repo | Changes |
|---|---|
| `runtime/orchestrator` | Add hermes-subprocess profile; wire `SubProcessAdapter` with Hermes binary + extraEnv |
| `runtime/executors/hermes` | New package: `src/index.ts`, `src/recovery.ts`, `src/briefing.ts` |

Repo IDs must match `workspace.yaml → repos[].id`.

## Validation and release impact

- Integration test: spawn the Hermes executor via the subprocess profile against a
  stub task; verify `result.json` appears with `terminal_status: "in_review"`.
- Abnormal-exit test: kill `hermes chat` mid-run; verify Layer 1 recovery produces a
  valid blocked `result.json` and a draft PR.
- Parallel-task test: two executor instances for the same workspace; verify no
  `HERMES_HOME` conflicts (each uses its own tmpdir under `EXECUTOR_WORKDIR`).
- No orchestrator ABI changes → no migration needed.
- Rollout: deploy as a named profile (`hermes-subprocess`); existing Claude executor
  profile is untouched. Operators opt in per workspace.
