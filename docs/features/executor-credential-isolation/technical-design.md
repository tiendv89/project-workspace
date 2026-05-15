# Technical Design

## Feature
- Feature ID: `executor-credential-isolation`
- Title: Executor Credential Isolation — remove model decisions from the orchestrator

## Current state

Two problems exist in the current boundary between orchestrator and executor:

### Problem 1 — credential leak via `process.env` spread

`SubProcessAdapter.submit()` builds the child environment with `...process.env`:

```typescript
const childEnv: NodeJS.ProcessEnv = {
  ...process.env,   // ← ANTHROPIC_API_KEY leaks into executor
  ...this.extraEnv,
  TASK_ID: taskId,
  // ...
};
```

`ANTHROPIC_API_KEY` is never explicitly passed — it leaks because the orchestrator's
ambient environment is spread wholesale into the executor process.

### Problem 2 — orchestrator reads and forwards model ID

`ExecutorPortInput` has:

```typescript
/** Model ID to use for the LLM; resolved from workspace model_policy. */
implementationModel?: string;
```

The orchestrator reads this from somewhere (workspace config, `model_policy`) and
passes it to the executor as `IMPLEMENTATION_MODEL`. This means:

- The orchestrator must understand model ID strings
- The orchestrator reads a task-execution concern (`execution.model`) that does not
  belong to it
- Any new executor that uses a different model field name or resolution strategy must
  also be reflected in the orchestrator

The right owner is the executor: it already clones the management repo in Phase 1 and
reads the full task YAML. Reading `execution.model` costs nothing extra.

## Constraints

- Existing deployments must not hard-break — deprecation path required.
- The ABI `ExecutorPortInput` type is shared; removing `implementationModel` is a
  breaking change that must be phased.
- The Claude executor must continue to accept `--model` via its own resolution, not
  via `IMPLEMENTATION_MODEL` env var.

## What changes

### 1. `TaskExecution` type — add `model` field

```typescript
// runtime/orchestrator/src/types/task.ts

export interface TaskExecution {
  actor_type: ActorType;
  last_updated_by: string | null;
  last_updated_at: string | null;
  suggested_next_step?: string | null;
  /**
   * Model ID the executor should use for this task.
   * Read directly by the executor from the task YAML — never forwarded
   * by the orchestrator. Absent = executor uses its own default.
   */
  model?: string | null;
}
```

Tech leads set this when writing task YAMLs:

```yaml
execution:
  actor_type: agent
  model: claude-sonnet-4-6      # or deepseek-v4-flash, etc.
```

The orchestrator never reads `execution.model` for dispatch purposes. It is purely a
task-spec field consumed by the executor.

### 2. `ExecutorPortInput` — deprecate `implementationModel`

```typescript
// runtime/abi/src/types.ts

export interface ExecutorInput {
  // ...
  /**
   * @deprecated — model selection is the executor's responsibility.
   * Executors must read execution.model from the task YAML directly.
   * This field will be removed in a future ABI version.
   */
  implementationModel?: string;
  // ...
}
```

Phase 1: field remains, marked deprecated. Orchestrator stops populating it. Any
executor that still reads `IMPLEMENTATION_MODEL` continues to work if the field
is absent (it was always optional).

Phase 2 (future feature): field removed from `ExecutorInput`, `IMPLEMENTATION_MODEL`
removed from `SubProcessAdapter.submit()`.

### 3. `SubProcessAdapter` — stop spreading `process.env`, drop `implementationModel`

```typescript
// Before
const childEnv: NodeJS.ProcessEnv = {
  ...process.env,
  ...this.extraEnv,
  TASK_ID: taskId,
  // ...
  ...(implementationModel ? { IMPLEMENTATION_MODEL: implementationModel } : {}),
};

// After
const childEnv: NodeJS.ProcessEnv = {
  PATH: process.env.PATH,   // executor needs PATH to find binaries
  HOME: process.env.HOME,   // executor needs HOME for git config
  ...this.extraEnv,         // operator extras: GIT_AUTHOR_EMAIL, ANTHROPIC_API_KEY (transitional)
  TASK_ID: taskId,
  FEATURE_ID: featureId,
  WORKSPACE_ID: workspaceId,
  HANDLE: handle,
  TASK_REPO_URL: taskRepoUrl,
  TASK_REPO_BRANCH: taskRepoBranch,
  TASK_BASE_BRANCH: taskBaseBranch,
  TASK_REPO_BASE_BRANCH: taskRepoBaseBranch,
  EXECUTOR_WORKDIR: executorWorkdir,
  MGMT_REPO_URL: mgmtRepoUrl,
  RESULT_PATH: resultPath,
  GITHUB_TOKEN: githubToken,
  ...(sshPrivateKey ? { SSH_PRIVATE_KEY: sshPrivateKey } : {}),
  ...(budgetTokens !== undefined ? { BUDGET_TOKENS: String(budgetTokens) } : {}),
  // implementationModel intentionally omitted — executor reads task YAML directly
  CALLBACK_URL: callbackUrl,
  NONCE: nonce,
  ...(this.executorBinPath ? { EXECUTOR_BIN: this.executorBinPath } : {}),
  CLAUDE_AGENT_RUNTIME: "1",
};
```

Two changes in one:
- `...process.env` removed → credential leak closed
- `IMPLEMENTATION_MODEL` removed → model selection no longer orchestrator concern

`ANTHROPIC_API_KEY` moves to `extraEnv` in the local-subprocess profile wiring
(see §5). In containerised profiles it is set on the executor container directly.

### 4. Claude executor — read `execution.model` from task YAML

The Claude executor already reads the task spec from the management repo clone during
Phase 1. It now also reads `execution.model` and uses it as the `--model` flag:

```typescript
// runtime/executors/claude/src/index.ts

// After Phase 1 (mgmt repo materialized), read task YAML
const taskYaml = readFileSync(
  path.join(WORKSPACE_ROOT, "docs", "features", FEATURE_ID, "tasks", `${TASK_ID}.yaml`),
  "utf8"
);
const task = parseYaml(taskYaml) as Task;

const model = task.execution?.model ?? process.env.CLAUDE_DEFAULT_MODEL ?? "claude-sonnet-4-6";
```

The `--model` flag is built from this resolved value. `CLAUDE_DEFAULT_MODEL` is an
optional env var on the executor image for operators who want a different fallback
without modifying task YAMLs.

The executor also validates its own credential:

```typescript
const apiKey = process.env.ANTHROPIC_API_KEY;
if (!apiKey) {
  writeResultAndExit({
    terminal_status: "blocked",
    blocked_reason: "missing_credential",
    blocked_suggestion: "Set ANTHROPIC_API_KEY in the executor container environment.",
  });
}
```

### 5. Local-subprocess profile wiring — `ANTHROPIC_API_KEY` moves to `extraEnv`

```typescript
// runtime/orchestrator/src/adapters/index.ts (local-subprocess profile)

const claudeAdapter = new SubProcessAdapter({
  extraEnv: {
    GIT_AUTHOR_EMAIL:  config.gitAuthorEmail,
    GIT_AUTHOR_NAME:   config.gitAuthorName,
    // Transitional: operators running local-subprocess set this here, not in orchestrator env
    ...(process.env.ANTHROPIC_API_KEY
      ? { ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY }
      : {}),
  },
  // ...
});
```

This is Phase 1 transitional wiring. In Phase 2 this line is removed entirely and
operators are expected to have moved the key to the executor image or a separate
credential injection mechanism.

### 6. Orchestrator deprecation warnings

```typescript
// runtime/orchestrator/src/bootstrap/bootstrap.ts

const MODEL_CREDENTIAL_VARS = ["ANTHROPIC_API_KEY", "DEEPSEEK_API_KEY", "OPENAI_API_KEY"];
for (const varName of MODEL_CREDENTIAL_VARS) {
  if (process.env[varName]) {
    emit({
      type: "deprecation_warning",
      var: varName,
      message: `${varName} detected in orchestrator environment. ` +
               `Move it to the executor container or SubProcessAdapterOpts.extraEnv. ` +
               `See executor-credential-isolation migration guide.`,
    });
  }
}

if (process.env.IMPLEMENTATION_MODEL) {
  emit({
    type: "deprecation_warning",
    var: "IMPLEMENTATION_MODEL",
    message: "IMPLEMENTATION_MODEL is deprecated. " +
             "Set execution.model in the task YAML instead.",
  });
}
```

### 7. ABI spec — credential boundary + model selection sections

`runtime/abi/docs/abi-spec.md` gains two new sections:

```
## Credential boundary

The orchestrator owns workflow credentials only:
  SSH_PRIVATE_KEY  — git operations on the management repo
  GITHUB_TOKEN     — workspace PR management

Model provider API keys (ANTHROPIC_API_KEY, DEEPSEEK_API_KEY, etc.) are
executor-internal. They must not appear in ExecutorPortInput or orchestrator config.
Executors source them from their own container environment.

## Model selection

The model an executor uses for a task is declared in the task YAML as
`execution.model`. Executors read this field from the task spec during Phase 1
startup (management repo is already cloned). The orchestrator never reads or forwards
the model field.

`implementationModel` in ExecutorPortInput is deprecated and will be removed. Do not
populate it in new adapters.
```

## Migration path

| | Before | Phase 1 (this feature) | Phase 2 (future) |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | orchestrator env, spreads to executor | executor env / `extraEnv`; deprecation warning if in orchestrator env | deprecation warning removed; `extraEnv` transitional wiring removed |
| Model selection | orchestrator reads `model_policy`, passes `IMPLEMENTATION_MODEL` | executor reads `task.execution.model` from task YAML; `implementationModel` deprecated | `implementationModel` removed from ABI types |
| `...process.env` spread | present in `SubProcessAdapter` | removed | — |

## Files changed

| File | Change |
|---|---|
| `runtime/abi/src/types.ts` | Mark `implementationModel` `@deprecated` |
| `runtime/abi/docs/abi-spec.md` | Add credential boundary + model selection sections |
| `runtime/orchestrator/src/types/task.ts` | Add `model?: string` to `TaskExecution` |
| `runtime/orchestrator/src/adapters/executor/subprocess.ts` | Remove `...process.env` spread; remove `IMPLEMENTATION_MODEL` injection |
| `runtime/orchestrator/src/adapters/executor/claude-docker-run.ts` | Same fixes for Docker adapter |
| `runtime/orchestrator/src/adapters/index.ts` | Move `ANTHROPIC_API_KEY` to `extraEnv` (transitional); stop passing `implementationModel` |
| `runtime/orchestrator/src/bootstrap/bootstrap.ts` | Add deprecation warnings for model credentials + `IMPLEMENTATION_MODEL` |
| `runtime/orchestrator/src/config/validate-agent-yaml.ts` | Remove any `ANTHROPIC_API_KEY` requirement |
| `runtime/executors/claude/src/index.ts` | Read `execution.model` from task YAML; validate own `ANTHROPIC_API_KEY`; remove `IMPLEMENTATION_MODEL` read |
| `runtime/orchestrator/docs/OPERATOR-GUIDE.md` | Add migration section |

## Dependency analysis

- No dependency on `adding-hermes-executor` — can ship independently.
- No dependency on `agent-runtime-selector` — `execution.model` and `execution.runtime`
  are independent fields; this feature adds `model`, the selector adds `runtime`.
- Should ship before `agent-runtime-selector` so the selector feature inherits the
  correct boundary from the start.

## Parallelisation

Single wave — all changes are in the `workflow` repo. No file depends on another
within this feature. Can be done in one PR.
