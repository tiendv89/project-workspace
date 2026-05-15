# Technical Design

## Feature
- Feature ID: `hermes-cluster-controller`
- Title: Hermes Cluster Controller — HTTP service for containerised Hermes executor dispatch

## Current State

`adding-hermes-executor` ships the Hermes executor via `SubProcessAdapter` wiring:
the orchestrator forks the Hermes executor binary as a child process on the same host.
Model and Mem0 config are injected via `SubProcessAdapterOpts.extraEnv` by the operator.

This is sufficient for local development but lacks topology abstraction (container /
K8s), model registry, and workspace config registry.

## Constraints

- The orchestrator ABI contract (`ExecutorPort`, `ExecutorInput`, `ExecutorResult`,
  callback protocol) must not change.
- The `SubProcessAdapter`-based local profile from `adding-hermes-executor` must
  continue to work — both profiles coexist.
- `result.json` must be delivered regardless of memory system availability.
- Parallel executors for the same workspace must not conflict on any shared state.

## Components

### 1. `HermesClusterAdapter`

New `ExecutorPort` implementation. Replaces the `SubProcessAdapter` wiring in the
cluster profile. The orchestrator instantiates it at bootstrap from profile config.

```typescript
// runtime/orchestrator/src/adapters/executor/hermes-cluster.ts

export class HermesClusterAdapter implements ExecutorPort {
  constructor(private opts: HermesClusterAdapterOpts) {}

  async submit(input: ExecutorPortInput): Promise<ExecutorHandle> {
    // POST input to cluster controller /submit
    // Controller returns { handle, nonce } immediately
    // Result arrives via callback — same broker protocol as SubProcessAdapter
    const resp = await fetch(`${this.opts.controllerUrl}/submit`, {
      method: "POST",
      body: JSON.stringify(input),
      headers: { Authorization: `Bearer ${this.opts.authToken}` },
    });
    const { handle } = await resp.json();
    return handle;
  }

  async readResult(_handle: ExecutorHandle): Promise<ExecutorResult> {
    // No-op — result arrives via callback
    return { terminal_status: "failed", blocked_reason: "use_callback" };
  }

  async ack(handle: ExecutorHandle): Promise<void> {
    await fetch(`${this.opts.controllerUrl}/ack/${handle}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${this.opts.authToken}` },
    });
  }
}
```

`HermesClusterAdapterOpts`: `controllerUrl`, `authToken`, `timeoutMs`.

### 2. Cluster Controller HTTP service

A small Go or Node service (separate deployment). Endpoints:

| Method | Path | Description |
|---|---|---|
| `POST` | `/submit` | Accept `ExecutorPortInput`, spawn executor, return `{ handle }` |
| `POST` | `/ack/:handle` | Acknowledge result delivery; trigger workdir cleanup |
| `GET` | `/health` | Liveness check |

#### Lifecycle per job

```
POST /submit
  → validate input (required fields, model in registry)
  → resolve model (3-level fallback)
  → resolve workspace config (Mem0, RAG MCP)
  → create workdir: ${WORKSPACES_DIR}/exec-{handle}/
  → spawn executor (via configured spawner)
  → watch for RESULT_PATH
  → on result.json detected: POST callback to CALLBACK_URL with { handle, nonce, result }
  → hand memory-candidates.json to consolidator queue (if present)
  → wait for POST /ack/:handle
  → delete workdir
```

On timeout (configurable, default 30 min):
```
  → SIGTERM executor, wait 30s, SIGKILL
  → write result.json: { terminal_status: "blocked", blocked_reason: "executor_timeout" }
  → POST callback
  → delete workdir
```

#### Model registry (`cluster-controller.yaml`)

```yaml
platform_default_model: deepseek-v4-flash

models:
  deepseek-v4-flash:
    provider: deepseek
    api_key_env: DEEPSEEK_API_KEY
  deepseek-v4-pro:
    provider: deepseek
    api_key_env: DEEPSEEK_API_KEY
  qwen3-27b:
    provider: ollama
    base_url: http://ollama.internal
    api_key_env: null

workspaces:
  workspace-abc:
    default_model: deepseek-v4-flash
    mem0_url: http://mem0.internal/workspace-abc
    mem0_api_key_env: MEM0_API_KEY_ABC
    rag_mcp_url: http://rag.internal
    rag_mcp_token_env: RAG_MCP_TOKEN
```

Resolution at spawn time:
```
input.implementationModel set and in registry?  → use it
workspace config has default_model?             → use it
platform_default_model                          → use it
model not in registry?                          → reject 400 unknown_model
```

#### Spawner implementations

Config field: `spawner: subprocess | docker | kubernetes`

**subprocess** — `child_process.spawn` / `exec.Command`. Workdir created on local
filesystem. Used for development and single-node deployments.

**docker** — `docker run --rm -v ${workdir}:${workdir} -e ... hermes-executor:latest`.
Workdir mounted into container. Model API keys injected as `-e` flags from controller env.

**kubernetes** — `kubectl apply` a `Job` manifest. Workdir mounted via `emptyDir` or
PVC (operator choice). Job TTL after completion removes the pod automatically.

The spawner is a strategy interface — adding a new topology requires only a new
implementation, no controller logic changes.

### 3. `HermesClusterAdapterOpts` profile config

```typescript
// runtime/orchestrator/src/adapters/index.ts  (hermes-cluster profile)

const hermesAdapter = new HermesClusterAdapter({
  controllerUrl: config.hermesControllerUrl,   // e.g. http://hermes-controller:8080
  authToken:     config.hermesControllerToken,
  timeoutMs:     config.hermesTimeoutMs ?? 1_800_000,  // 30 min default
});
```

No model credentials, no Mem0 config, no Hermes env vars appear in the orchestrator
profile. All of that lives in the cluster controller.

## Options Considered

### Option A: Controller resolves model; orchestrator passes raw `implementationModel`
- Pro: orchestrator stays thin; model resolution in one place
- Con: `implementationModel` in `ExecutorPortInput` is already deprecated
  (`executor-credential-isolation`); propagating it further moves in the wrong direction
- **Chosen** — acceptable for now because the cluster controller is the resolution
  boundary, not the orchestrator. The orchestrator passes a hint; the controller decides.

### Option B: Executor reads `task.execution.model` directly (no controller resolution)
- Pro: cleanest boundary; no model knowledge in the controller either
- Con: executor must clone mgmt repo before the controller knows which model to inject;
  creates a chicken-and-egg for pre-spawn credential injection in Docker/K8s mode
- **Rejected** for cluster mode; valid for subprocess mode (already done in
  `executor-credential-isolation`)

### Option C: Static executor image with all credentials baked in
- Pro: simplest spawn — no env var injection needed
- Con: one image per model/credential combo; operationally unmaintainable
- **Rejected**

## Data flow summary

```
Orchestrator
  → HermesClusterAdapter.submit(input)
  → POST /submit to cluster controller

Cluster controller
  → resolves model + workspace config
  → creates workdir
  → spawns executor (subprocess / docker / k8s)
  → watches for result.json

Hermes executor process/container
  → Phase 1–8 (same as adding-hermes-executor)
  → writes result.json + memory-candidates.json
  → exits 0

Cluster controller
  → detects result.json
  → POST callback to broker
  → hands memory-candidates.json to consolidator queue
  → waits for ack
  → deletes workdir

Orchestrator reap loop
  → reads ExecutorResult from broker
  → updates task YAML, records pr_url
  → calls ack() → POST /ack/:handle
```

## Dependency Analysis

| Dependency | Status | Notes |
|---|---|---|
| `adding-hermes-executor` | prerequisite | Hermes executor binary and ABI contract must exist |
| `executor-credential-isolation` | recommended before | Ensures `implementationModel` deprecation path is in place |
| `agent-runtime-split` | done | ExecutorPort interface |
| `runtime/abi/src/types.ts` | done | No changes needed |

## Parallelisation / Blocking Analysis

- **T1 (`HermesClusterAdapter`)** — unblocked once `ExecutorPort` interface is stable
- **T2 (Cluster controller HTTP service + model registry)** — unblocked; standalone service
- **T3 (Spawner implementations)** — T2 must exist (strategy interface); subprocess first, docker + k8s after
- **T4 (Profile wiring + operator guide)** — depends on T1 + T2
- **T5 (Tests + integration)** — depends on T1, T2, T3

T1 and T2 can be implemented in parallel. T3 can proceed once T2's spawner interface
is defined. T4 and T5 gate on T1–T3.
