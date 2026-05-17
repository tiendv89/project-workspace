# Product Specification

## Feature
- Feature ID: `adding-hermes-executor`
- Title: Hermes Executor — ABI-conformant executor image for Hermes Agent

## Problem

Every task in the workflow runs on the Claude executor today. Claude is powerful but
carries a non-trivial API cost per task. Many tasks are mechanical — boilerplate
generation, doc updates, simple refactors — where a cheaper runtime produces equally
good output.

Hermes Agent (NousResearch, MIT license) is a self-hostable agent platform that
supports any OpenAI-compatible model endpoint, including local models via Ollama or
llama.cpp.

This feature introduces Hermes as a second executor — minimum viable wiring only.
It is the prerequisite for `agent-runtime-selector` (routing) and
`hermes-workspace-memory` (persistent knowledge accumulation).

## Goals

1. **Hermes executor via SubProcessAdapter — orchestrator-blind** — the orchestrator
   spawns the Hermes executor as a child process by wiring the existing
   `SubProcessAdapter` with `executorBinPath` pointed at the Hermes executor binary.
   No new adapter class is required. The orchestrator has no knowledge of Hermes
   internals beyond what is declared in `SubProcessAdapterOpts.extraEnv` by the
   operator. The Hermes cluster controller (HTTP service, container orchestration,
   model registry) is deferred to `hermes-cluster-controller`.

2. **Ephemeral executor process with ephemeral `HERMES_HOME`** — each task execution
   spawns a fresh Hermes process with `HERMES_HOME` pointed at an ephemeral tmpdir.
   Nothing persists after the process exits. Workspace memory accumulation is deferred
   to `hermes-workspace-memory`.

3. **ABI contract unchanged** — the orchestrator's side of the contract does not
   change. It calls `submit(input)` and receives an `ExecutorResult` via callback.
   The Hermes executor handles everything between those two events.

4. **Layer 1 termination safety** — the `hermes chat` spawn is wrapped in a
   `try/finally` that fires regardless of how Hermes exits: commit dirty tree, open
   draft PR if needed, write `result.json` with `terminal_status: "blocked"` if
   Hermes did not produce a valid result. Same recovery contract as the Claude executor.

5. **Responsibility split — Hermes codes, wrapper handles workflow protocol** —
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

## Non-goals

- **Orchestrator dispatch routing and model selection** — `execution.runtime` and
  `execution.model` on task YAMLs, per-task model/provider resolution, and the
  orchestrator's runtime-selection logic are `agent-runtime-selector`'s scope.
  The Hermes executor accepts model and provider via `HERMES_INFERENCE_MODEL` /
  `HERMES_INFERENCE_PROVIDER` env vars; which values to inject is the selector's decision.
- **Hermes cluster controller** — the HTTP service, container/K8s job spawning, model
  registry, and workdir lifecycle management are deferred to `hermes-cluster-controller`.
- **Workspace memory / Mem0 integration** — persistent knowledge accumulation,
  `memory-candidates.json` output, and the memory consolidator service are deferred
  to `hermes-workspace-memory`. This executor runs stateless by default.
- **Reviewer executor for Hermes** — `kind=impl` tasks only in this feature. Review
  capability is deferred to `executor-capability`.
- **Modifying Hermes internals** — the executor uses Hermes as-is via its published
  CLI. No fork required.
- **Local model infrastructure** — Ollama / llama.cpp hosting is out of scope.
- **Model registry / three-level fallback** — deferred to `hermes-cluster-controller`.
- **Fixing Claude executor credential injection** — tracked as
  `executor-credential-isolation`, explicitly out of scope here. The Hermes executor
  is designed correctly from the start: model credentials live in `extraEnv`, never
  in the orchestrator.

## Architecture overview

```
Orchestrator
  │  submit(ExecutorPortInput) via SubProcessAdapter
  │  (executorBinPath = hermes-executor/dist/index.js)
  │  (extraEnv = HERMES_INFERENCE_MODEL, HERMES_INFERENCE_PROVIDER,
  │              DEEPSEEK_API_KEY, ...)
  ▼
Hermes Executor process (ephemeral)
  ├── Phase 1: clone mgmt repo (read-only)
  ├── Phase 2: clone impl repo
  ├── Phase 3: write HERMES_HOME/config.yaml (MCP)
  │     HERMES_HOME = ${EXECUTOR_WORKDIR}/hermes-home (tmpdir)
  ├── Phase 4: build briefing from mgmt clone
  ├── Phase 5: hermes chat --query "$BRIEFING" --quiet --ignore-rules
  │     Hermes makes code changes and saves files only
  ├── Phase 6: wrapper commits + pushes + opens impl PR + writes result.json
  └── exits 0
```

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

Model and provider are passed as env vars; which values to set is resolved by the
selector before the executor is spawned — the executor has no selection logic.

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
| `RAG_MCP_URL` | RAG MCP server URL (written to `HERMES_HOME/config.yaml`, optional) |
| `RAG_MCP_TOKEN` | RAG MCP auth token (optional) |

These are set by the operator in `SubProcessAdapterOpts.extraEnv` when wiring the
Hermes executor profile. Which model and provider to use is resolved by
`agent-runtime-selector` — the executor accepts whatever values are injected.

## Success criteria

- A task executes end-to-end via the Hermes executor: repos materialised, work
  committed, impl PR opened, valid `result.json` written.
- Two parallel tasks for the same workspace run without conflict (each has its own
  isolated `HERMES_HOME`).
- The executor exits 0 and produces a valid `result.json` even when Hermes exits
  abnormally (Layer 1 recovery fires).
- The orchestrator requires no changes.
