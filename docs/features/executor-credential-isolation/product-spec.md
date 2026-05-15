# Product Specification

## Feature
- Feature ID: `executor-credential-isolation`
- Title: Executor Credential Isolation — remove model decisions from the orchestrator

## Problem

The orchestrator currently makes two model-related decisions that are not its
responsibility:

**1. It holds model credentials.**
`ANTHROPIC_API_KEY` lives in the orchestrator's environment and leaks into the Claude
executor via `...process.env` spread. The orchestrator is a workflow state machine. It
never invokes a model, never selects a provider. Holding model API keys broadens its
attack surface, couples its config to executor choices, and contradicts the
ports-and-adapters design where executor internals are opaque.

**2. It reads and forwards the model ID.**
`implementationModel` is read by the orchestrator from somewhere (workspace
`model_policy`, config, or task YAML) and forwarded to the executor via
`ExecutorPortInput`. This means the orchestrator must understand model IDs, know which
field in the task carries the selection, and participate in a decision that belongs
entirely to the executor infrastructure.

The right boundary is clear:

```
Orchestrator owns:
  SSH_PRIVATE_KEY   — git operations on the management repo
  GITHUB_TOKEN      — workspace PR management

Executor infrastructure owns:
  ANTHROPIC_API_KEY / DEEPSEEK_API_KEY / ...  — model credentials
  model selection    — read from task.execution.model in the task YAML directly
```

The task YAML is the authoritative declaration of how a task should run. The executor
already clones the management repo (Phase 1 of the ABI startup protocol) and reads the
task spec from it. Reading `execution.model` from there is natural — no orchestrator
involvement required.

## Goals

1. **Remove `ANTHROPIC_API_KEY` from the orchestrator's environment** — `agent.yaml`
   must not require or accept any model provider API key. The orchestrator emits a
   deprecation warning if any model credential is detected in its environment.

2. **Claude executor sources its own credential** — `ANTHROPIC_API_KEY` is set on the
   executor container (or `SubProcessAdapterOpts.extraEnv` for the local-subprocess
   profile). The orchestrator does not pass it and does not need it.

3. **`execution.model` declared in task YAML, read by executor** — tech leads set
   `execution.model` on the task (e.g. `claude-sonnet-4-6`, `deepseek-v4-flash`).
   The executor reads this field from the task YAML during Phase 1 startup (management
   repo is already cloned). The orchestrator never reads or forwards the model field.

4. **`implementationModel` removed from `ExecutorPortInput`** — the ABI field
   `implementationModel` (and its env var `IMPLEMENTATION_MODEL`) is deprecated and
   removed. Model selection is not an orchestrator concern and must not appear in the
   orchestrator-to-executor contract.

5. **`TaskExecution.model` added to task schema** — a new optional field
   `execution.model` is added to the task YAML type (`TaskExecution`). If absent, the
   executor falls back to its own configured default. The orchestrator does not read
   this field for dispatch purposes.

6. **Backward-compatible migration** — existing deployments must not hard-break:
   - Phase 1 (this feature): executor reads `execution.model` from task YAML;
     orchestrator deprecation warning emitted if `ANTHROPIC_API_KEY` or
     `IMPLEMENTATION_MODEL` detected; `implementationModel` in `ExecutorPortInput`
     is marked `@deprecated` but still accepted
   - Phase 2 (future): `implementationModel` removed from ABI types entirely

7. **Documented boundary** — ABI spec and operator guide gain explicit sections on
   the credential boundary and model selection ownership.

## Non-goals

- **Credential store / secrets manager** — credentials stay in env vars; this feature
  only moves which process owns them.
- **Hermes executor credentials** — the Hermes cluster controller already follows the
  correct pattern. No changes needed there.
- **Rotating or auditing credentials** — operational concern, out of scope.
- **`SSH_PRIVATE_KEY`, `GITHUB_TOKEN`** — legitimate workflow credentials; stay in
  `ExecutorPortInput` unchanged.
- **`agent-runtime-selector` routing** — that feature adds `execution.runtime` to task
  YAMLs and orchestrator dispatch logic. This feature only adds `execution.model` and
  ensures the orchestrator does not read it.

## Success criteria

- `agent.yaml` schema has no model provider API key field.
- `ExecutorPortInput` has no `implementationModel` field (or it is `@deprecated`
  and ignored).
- The Claude executor reads `execution.model` from task YAML and uses it as the
  `--model` flag; falls back to a built-in default if absent.
- The orchestrator passes no model ID and no model credential to any executor.
- `TaskExecution` type has `model?: string`.
- Existing deployments work during Phase 1 with deprecation warnings only.
