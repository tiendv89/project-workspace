# Product Specification

## Feature
- Feature ID: `adding-hermes-executor`
- Title: Hermes Executor — Workspace-aware agent cluster as a second executor

## Problem

Every task in the workflow runs on the Claude executor today. Claude is powerful but
carries a non-trivial API cost per task. Many tasks are mechanical — boilerplate
generation, doc updates, simple refactors — where a cheaper runtime produces equally
good output.

Beyond cost, the Claude executor is stateless between task runs. Each execution starts
with no knowledge of the workspace it is operating in. Codebase conventions, team
patterns, architectural decisions — all must be re-discovered from scratch on every
task. There is no accumulation across executions.

Hermes Agent (NousResearch, MIT license) is a self-hostable agent platform that
supports any OpenAI-compatible model endpoint, including local models via Ollama or
llama.cpp. It has a pluggable memory provider system designed for exactly this
accumulation story — agents that grow smarter with each run against the same workspace.

This feature introduces Hermes as a second executor. It is the prerequisite for
`agent-runtime-selector`, which will add per-task routing in the orchestrator.

## Goals

1. **Hermes executor via SubProcessAdapter — orchestrator-blind** — the orchestrator
   spawns the Hermes executor as a child process by wiring the existing
   `SubProcessAdapter` with `executorBinPath` pointed at the Hermes executor binary.
   No new adapter class is required. The orchestrator has no knowledge of Hermes
   internals: no Mem0 configuration, no model registry, no Hermes-specific env vars
   beyond what are declared in `SubProcessAdapterOpts.extraEnv` by the operator.
   The Hermes cluster controller (HTTP service, container orchestration, model
   registry) is deferred to `hermes-cluster-controller`.

2. **Ephemeral executor containers with ephemeral `HERMES_HOME`** — each task
   execution spawns a fresh Hermes container with `HERMES_HOME` pointed at an
   ephemeral tmpdir. Nothing persists in the local tmpdir after the container exits.
   Workspaces that have opted into the persistent knowledge layer (Goal 3) have Mem0
   configured — Hermes connects at session start and loads accumulated workspace
   knowledge into context. Workspaces that have not opted in run without a memory
   provider: each session starts from the briefing and codebase alone, with no
   cross-session knowledge.

3. **Workspace-scoped Mem0 for persistent knowledge** — each workspace has a
   dedicated Mem0 instance (or namespace). At session start, Hermes loads the
   workspace's accumulated knowledge from Mem0 — codebase conventions, team patterns,
   known architectural facts. This knowledge is inherited by every executor that runs
   against the workspace, regardless of which task it is executing.

4. **Knowledge capture via `memory-candidates.json`** — when the executor finishes,
   it writes a structured file of new observations alongside `result.json`. This file
   is the executor's only output to the memory system. The executor never writes
   directly to Mem0.

5. **Memory consolidator service (optional)** — a separate service within the Hermes
   cluster watches the memory queue and drains `memory-candidates.json` files into
   Mem0. If the consolidator is not deployed, execution degrades gracefully to
   stateless — no memory accumulation, no failures.

6. **Memory never blocks executor exit** — `result.json` is the executor's critical
   output. Memory capture is best-effort and entirely decoupled: the executor exits
   after writing `result.json`, regardless of memory system state.

7. **ABI contract unchanged** — the orchestrator's side of the contract does not
   change. It calls `submit(input)` and receives an `ExecutorResult` via callback.
   The Hermes cluster internally handles everything between those two events.

8. **Layer 1 termination safety** — the `hermes chat` spawn is wrapped in a
   `try/finally` that fires regardless of how Hermes exits: commit dirty tree, open
   draft PR if needed, write `result.json` with `terminal_status: "blocked"` if
   Hermes did not produce a valid result. Same recovery contract as the Claude executor.

9. **Runtime model selection** — model and provider are set via env vars
   (`HERMES_INFERENCE_MODEL`, `HERMES_INFERENCE_PROVIDER`) injected through
   `SubProcessAdapterOpts.extraEnv` by the operator. Once `executor-credential-isolation`
   lands, the executor also reads `task.execution.model` from the task YAML directly
   as the first-priority override. Platform default is `deepseek-v4-flash` / `deepseek`.
   All provider API keys live in `extraEnv`; the orchestrator is not involved in model
   selection. The model registry and three-level fallback resolution are deferred to
   `hermes-cluster-controller`.

10. **Responsibility split — Hermes codes, wrapper handles workflow protocol** —
    Hermes does not auto-inject `CLAUDE.md` and has no built-in knowledge of
    workflow conventions (git patterns, PR body format, `result.json` schema,
    `pr-create` skill). Delegating the full output contract to Hermes via the briefing
    is not safe.

    The executor wrapper (`src/index.ts`) owns all workflow-protocol actions:
    - **Pre-execution**: clone repos (Phase 1 + 2), write `HERMES_HOME/config.yaml`
    - **Hermes scope**: briefing instructs Hermes to make the required code changes
      and save files only — no git, no PR, no result.json
    - **Post-execution**: wrapper commits and pushes changes, opens the impl PR via
      the same `pr-create` curl logic used by the Claude executor, writes `result.json`
    - **Layer 1 recovery**: `try/finally` wraps the Hermes spawn; recovery routine
      handles dirty-tree commit, draft PR, and blocked result on abnormal exit

    This mirrors the Claude executor's wrapper pattern and keeps workflow-protocol
    knowledge out of the model prompt entirely. The briefing to Hermes is scoped to:
    task description, technical design, subtasks, and codebase context — nothing about
    git or result files.

## Model

**Default: DeepSeek V4-Flash** (`deepseek-v4-flash` via the `deepseek` provider).

DeepSeek V4-Flash is the platform default for Hermes-routed tasks: 284B total / 13B
active parameters, 1M context window, full tool use and function calling support,
OpenAI-compatible API, and MIT-licensed weights. At $0.14/$0.28 per million
input/output tokens it is approximately 34× cheaper than Claude Sonnet 4.6 for the
same task volume.

Local models (Ollama) are a planned future tier once GPU infrastructure is in place.
The model registry design in this feature accommodates them without code changes.

## Non-goals

- **Orchestrator dispatch routing** — `execution.runtime` on task YAMLs and the
  orchestrator's runtime-selection logic are `agent-runtime-selector`'s scope.
- **Hermes cluster controller** — the HTTP service, container/K8s job spawning, model
  registry, workspace Mem0 config registry, and workdir lifecycle management are
  deferred to `hermes-cluster-controller`.
- **Reviewer executor for Hermes** — `kind=impl` tasks only. Review is out of scope.
- **PVC per executor** — not needed. Mem0 holds the persistent layer; the process is
  intentionally ephemeral.
- **Shared Hermes state across parallel executors** — each executor has its own
  isolated `HERMES_HOME`. Cross-executor workspace knowledge flows through Mem0, not
  through a shared filesystem.
- **SQLite coordination** — each executor has its own SQLite (in its ephemeral
  `HERMES_HOME`). No sharing, no locking, no linearisation layer required.
- **Modifying Hermes internals** — the executor uses Hermes as-is via its published
  CLI and memory provider API. No fork required.
- **Local model infrastructure** — Ollama / llama.cpp hosting is out of scope for
  this feature.
- **Model registry / three-level fallback** — deferred to `hermes-cluster-controller`.
- **Fixing Claude executor credential injection** — tracked as `executor-credential-isolation`,
  explicitly out of scope here. The Hermes executor is designed correctly from the
  start: model credentials live in `extraEnv`, never in the orchestrator.

## Architecture overview

```
Orchestrator
  │  submit(ExecutorPortInput) via SubProcessAdapter
  │  (executorBinPath = hermes-executor/dist/index.js)
  │  (extraEnv = HERMES_INFERENCE_MODEL, HERMES_INFERENCE_PROVIDER,
  │              DEEPSEEK_API_KEY, MEM0_URL, MEM0_API_KEY, ...)
  ▼
Hermes Executor process (ephemeral)
  ├── Phase 1: clone mgmt repo (read-only)
  ├── Phase 2: clone impl repo
  ├── Phase 3: write HERMES_HOME/config.yaml (Mem0 + MCP)
  │     HERMES_HOME = ${EXECUTOR_WORKDIR}/hermes-home (tmpdir)
  ├── Phase 4: build briefing from mgmt clone
  ├── Phase 5: hermes chat --query "$BRIEFING" --quiet --ignore-rules
  │     Hermes loads Mem0 at session start (inherits workspace knowledge)
  │     Hermes makes code changes and saves files only
  ├── Phase 6: wrapper commits + pushes + opens impl PR + writes result.json
  ├── Phase 7: writes memory-candidates.json (best-effort)
  └── exits 0

Memory consolidator (optional, separate process)
  watches HERMES_MEMORY_QUEUE_PATH
  drains memory-candidates.json → Mem0
  if absent → graceful no-op

Mem0 instance (per workspace, optional)
  if absent → stateless execution, no accumulation
```

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

The executor produces exactly two output files. They have separate consumers and
separate failure modes:

| File | Consumer | Failure mode |
|---|---|---|
| `result.json` at `RESULT_PATH` | Orchestrator (via callback) | Task blocked — must not fail |
| `memory-candidates.json` at `HERMES_MEMORY_QUEUE_PATH` | Memory consolidator | Observation lost — acceptable |

`result.json` is on the critical path. `memory-candidates.json` is best-effort.
The executor writes `result.json` first, then attempts `memory-candidates.json`.
A failure writing `memory-candidates.json` is logged and ignored.

## Invocation

```bash
HERMES_HOME="${EXECUTOR_WORKDIR}/hermes-home" \
HERMES_INFERENCE_MODEL="${HERMES_MODEL}" \
HERMES_INFERENCE_PROVIDER="${HERMES_PROVIDER}" \
HERMES_MAX_ITERATIONS="${HERMES_MAX_TURNS:-150}" \
HERMES_YOLO_MODE=1 \
hermes chat \
  --query  "${BRIEFING_CONTENT}" \
  --quiet \
  --ignore-rules
```

Model and provider are set via env vars rather than CLI flags so the cluster
controller can inject them without constructing a flag string.

## Environment variables

### ABI inputs (from orchestrator, unchanged)

| Variable | Description |
|---|---|
| `TASK_ID` | Task identifier |
| `FEATURE_ID` | Feature identifier |
| `WORKSPACE_ID` | Workspace identifier |
| `HANDLE` | Executor invocation UUID |
| `TASK_REPO_URL` | Implementation repo git URL |
| `TASK_REPO_BRANCH` | Feature branch to check out and push to |
| `TASK_BASE_BRANCH` | PR target branch |
| `TASK_REPO_BASE_BRANCH` | Impl repo root base branch |
| `EXECUTOR_WORKDIR` | Per-handle base directory |
| `MGMT_REPO_URL` | Management repo git URL (read-only) |
| `RESULT_PATH` | Path to write `result.json` |
| `SSH_PRIVATE_KEY` | Private key for git push |
| `GITHUB_TOKEN` | Token for opening impl PR |

### Hermes executor inputs (injected via `SubProcessAdapterOpts.extraEnv`, never by orchestrator core)

| Variable | Description |
|---|---|
| `HERMES_INFERENCE_MODEL` | Model ID (e.g. `deepseek-v4-flash`) — operator-configured |
| `HERMES_INFERENCE_PROVIDER` | Provider (e.g. `deepseek`) — operator-configured |
| `DEEPSEEK_API_KEY` | DeepSeek API credential — operator-configured in `extraEnv` |
| `HERMES_MAX_TURNS` | Max tool iterations (default 150) |
| `MEM0_URL` | Mem0 instance URL for this workspace (optional) |
| `MEM0_API_KEY` | Mem0 auth token (optional) |
| `RAG_MCP_URL` | RAG MCP server URL (written to `HERMES_HOME/config.yaml`, optional) |
| `RAG_MCP_TOKEN` | RAG MCP auth token (optional) |
| `HERMES_MEMORY_QUEUE_PATH` | Path to write `memory-candidates.json` (optional) |

These are set by the operator in `SubProcessAdapterOpts.extraEnv` when wiring the
Hermes executor profile. Once `executor-credential-isolation` lands, the executor also
reads `task.execution.model` directly from the task YAML as a first-priority override.
The model registry and automatic three-level fallback resolution are `hermes-cluster-controller` scope.

## Success criteria

- A task executes end-to-end via the Hermes executor: repos materialised, work
  committed, impl PR opened, valid `result.json` written.
- Two parallel tasks for the same workspace run without conflict.
- A second executor for the same workspace inherits observations written by the first
  (when the consolidator is running).
- If Mem0 and the consolidator are absent, the executor completes normally with no
  errors — stateless degradation.
- The executor exits 0 and produces a valid `result.json` even when Hermes exits
  abnormally (Layer 1 recovery fires).
- The orchestrator requires no changes.
