# Product Specification

## Feature
- Feature ID: `hermes-cluster-controller`
- Title: Hermes Cluster Controller — HTTP service for containerised Hermes executor dispatch

## Problem

`adding-hermes-executor` ships the Hermes executor as a local subprocess (same host,
same process tree as the orchestrator). This works for development and single-node
deployments, but it has two limits:

1. **No topology abstraction** — the orchestrator host must have the Hermes binary,
   model credentials, and Mem0 connectivity. As the platform scales to multi-tenant or
   multi-node deployments, executor workloads need to run in isolated containers or K8s
   Jobs — not on the orchestrator host.

2. **No model registry** — operators must set `HERMES_INFERENCE_MODEL`,
   `HERMES_INFERENCE_PROVIDER`, and provider API keys manually in `extraEnv` per
   deployment. There is no workspace-level default, no per-task override resolution,
   and no central place to register new model providers.

The Hermes Cluster Controller solves both: it is a small HTTP service that accepts job
submissions from the orchestrator, resolves the model from a registry, spawns an
executor container (subprocess / Docker / K8s Job), monitors for `result.json`, and
delivers the result back to the orchestrator via the existing callback protocol.

## Goals

1. **HTTP job submission** — the orchestrator submits tasks via a new
   `HermesClusterAdapter` implementing `ExecutorPort`. It POSTs `ExecutorPortInput` to
   the controller and returns immediately. Result arrives via the existing broker
   callback protocol.

2. **Topology-agnostic spawning** — the controller spawns executor processes in one of
   three modes, selected by config: `subprocess` (local process), `docker` (`docker run`),
   or `kubernetes` (K8s Job). The orchestrator has no knowledge of which topology is
   active.

3. **Model registry** — the controller holds a static model registry mapping model IDs
   to provider + API key env var. Resolution uses a three-level fallback:
   `input.implementationModel` (from `task.execution.model`) → workspace default →
   platform default (`deepseek-v4-flash`). Unknown model IDs are rejected before spawn.

4. **Workspace config registry** — the controller holds a per-workspace config table:
   Mem0 URL + API key, RAG MCP URL + token, default model. Injected into the executor
   container at spawn time.

5. **Workdir lifecycle** — the controller creates and cleans up the executor workdir
   (`${WORKSPACES_DIR}/exec-{handle}/`). On normal exit it removes the workdir after
   the callback is acknowledged. On timeout it force-kills and cleans up.

6. **Memory candidate routing** — after the callback is sent, the controller hands
   `memory-candidates.json` (if present) to the memory consolidator queue.

7. **ABI contract unchanged** — the orchestrator's side of the contract does not
   change. `HermesClusterAdapter` implements the same `ExecutorPort` interface as
   `SubProcessAdapter`. No orchestrator core changes are required.

## Non-goals

- **Replacing `SubProcessAdapter` wiring** — the local-subprocess profile from
  `adding-hermes-executor` is not removed. Both profiles coexist; operators choose
  which to deploy.
- **Auto-scaling / bin-packing** — the controller spawns one executor per job and does
  not manage concurrency limits or resource scheduling.
- **Multi-controller federation** — single controller instance per deployment.
- **Dynamic model registry updates** — the registry is static config; hot-reload is
  not required.
- **Reviewer executor for Hermes** — `kind=impl` tasks only.

## Success criteria

- A task submitted via `HermesClusterAdapter` executes end-to-end: repos materialised,
  work committed, impl PR opened, valid `result.json` written, callback delivered.
- Two parallel tasks for the same workspace run in isolated workdirs without conflict.
- Changing `spawner` from `subprocess` to `docker` requires only a config change.
- If the executor times out, the controller force-kills, cleans up, and delivers a
  `terminal_status: "blocked"` result to the orchestrator.
- The orchestrator requires no changes.
