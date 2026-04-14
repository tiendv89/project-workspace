# Product Specification

## Feature
- Feature ID: `agent-runtime-hardening`
- Title: Agent runtime hardening — Claude Code environment, full bootstrap, and credential delivery

## Problem

The distributed-agent-team v1 runtime (`agent-runtime/`) is functionally complete but has three gaps that prevent reliable production use:

**Gap 1 — SSH credential delivery is file-mount only.**
`bootstrap.ts` and every git operation resolve the SSH key from a file path (`SSH_KEY_PATH`). This works in Docker Compose (host `~/.ssh` is volume-mounted) but is awkward in Kubernetes (requires a Secret-backed volume) and does not work in GitHub Actions or other CI systems where secrets are injected as environment variables, not files. There is no way to pass the key as an environment variable.

**Gap 2 — Bootstrap only clones the management repo.**
`bootstrap.ts` clones the repos listed in `agent.yaml` `watches:` (the management repo). It does not read `workspace.yaml` inside that repo or clone the implementation repos declared there (`repos[]`). When `run-task.ts` resolves `taskRepoRoot` at runtime, those repos may not exist on disk, causing the task to fail immediately. Additionally, `workspace.yaml` declares `local_path: env:<VAR>` for each repo but nothing ever sets those env vars — the runtime silently falls back to a path that may not exist.

**Gap 3 — The agent container is not a Claude Code environment.**
The distributed-agent-team product spec describes the agent as an engineer working at their machine using Claude Code. The v1 runtime implements this by calling the Anthropic API directly with a hand-rolled tool-use loop — bypassing the entire Claude Code skill system. As a result, the existing workflow skills (`start-implementation`, `pr-self-review`, `pr-create`) never run inside the container. The `pr-create` skill — which handles branch push, GitHub REST API call, and task PR metadata update — is never invoked, so no PR is ever created. `GITHUB_TOKEN` is not a declared required env var, so operators have no signal it is needed. The loop in `run-task.ts` reimplements from scratch what Claude Code already does.

## Goals

1. **SSH key deliverable via environment variable.** Operators can pass `SSH_PRIVATE_KEY` (raw PEM content) as an env var. The runtime writes it to a `0400` temp file at startup and uses it for all git operations. `SSH_KEY_PATH` (file path) remains supported as a fallback. This makes credential delivery consistent across Docker Compose, Kubernetes, GitHub Actions, and any other runner.

2. **Bootstrap clones all repos declared in `workspace.yaml`.** After cloning the management repo, `bootstrap.ts` reads `workspace.yaml`, finds every repo in `repos[]` that is not the management repo itself, and clones or pulls each one into `workspacesRoot` at a predictable path. Bootstrap is the single place responsible for ensuring all repos are present before any task runs.

3. **Bootstrap populates repo local-path env vars.** For each repo whose `workspace.yaml` entry declares `local_path: env:<VAR>`, bootstrap sets `process.env[VAR]` to the resolved path after cloning. `resolveRepoLocalPath` in `main.ts` always finds the value via the env var lookup — no silent fallback.

4. **The agent container is a proper Claude Code environment.** The Docker image bundles the Claude Code CLI (`claude`). After a task is claimed, instead of running a raw Anthropic API loop, the runtime invokes `claude -p "..."` in the implementation repo directory. Claude Code's full skill system is available — `start-implementation`, `pr-self-review`, and `pr-create` all run naturally as part of the agent's execution contract, exactly as the product spec intended.

5. **An agent-specific `CLAUDE.md` tells Claude Code it is running as an automated agent.** The container writes a `CLAUDE.md` (or injects agent context into the existing one) before invoking `claude`. This file tells Claude Code: which task has been claimed, where the workspace is, that it must follow the `start-implementation` → work → `pr-self-review` → `pr-create` sequence without waiting for human input, and what the exit condition is. This is the "employee at their machine" simulation — the `CLAUDE.md` is the briefing note left on the desk.

6. **`GITHUB_TOKEN` is a required, documented input.** The token is declared alongside `ANTHROPIC_API_KEY` and `GIT_AUTHOR_EMAIL` as a required env var in `DOCKER.md`, `.env.example`, and the K8s manifest. It is needed by the `pr-create` skill to call the GitHub REST API. Without it, `pr-create` fails and no PR is opened.

7. **`run-task.ts` is replaced by a thin Claude Code CLI invocation.** The 800-line raw API loop is removed. The runtime's job is: set up context → invoke `claude -p "..."` → observe exit code → update task state. Budget is enforced via `--max-turns` (Claude Code's flag). This dramatically reduces owned runtime code while gaining the full expressiveness of the Claude Code environment.

## Non-goals

1. Building a new tool-use loop or agent harness — the whole point is to delegate this to Claude Code CLI.
2. Per-agent skill lists — agents remain full-stack uniform fleet; skills are declared per-task in `tasks.md`.
3. HTTPS-based git authentication — SSH-only for repo sync; `GITHUB_TOKEN` is used only for the GitHub REST API via `pr-create`.
4. Automatic PR merging — the agent opens the PR; a human approves and merges.
5. Multi-key SSH support — one key covers all repos in the workspace.

## User stories

1. **As an operator deploying to Kubernetes**, I can store the SSH private key in a K8s Secret and inject it as `SSH_PRIVATE_KEY` env var — no volume mount required.
2. **As an operator using GitHub Actions**, I can pass `SSH_PRIVATE_KEY: ${{ secrets.SSH_KEY }}` directly to the container without any file staging step.
3. **As an operator**, I add `GITHUB_TOKEN` to my container env once and every agent activation automatically opens a PR when the task is complete — because the `pr-create` skill runs naturally inside Claude Code.
4. **As a tech lead**, I add a new implementation repo to `workspace.yaml` and the agent clones it and sets its local path env var on next bootstrap — no manual env var configuration needed.
5. **As a developer reviewing agent output**, I see a PR appear in GitHub automatically when the agent finishes — the full `start-implementation` → work → `pr-self-review` → `pr-create` sequence runs exactly as it does for a human using Claude Code, because the agent IS using Claude Code.

## Architectural direction

The agent container is a simulation of an engineer's working machine:

| Human engineer | Agent container |
|---|---|
| Laptop with Claude Code installed | Docker image with `claude` CLI installed |
| Reads team `CLAUDE.md` | Container writes an agent `CLAUDE.md` with task context |
| Runs `/start-implementation` | Runtime invokes `claude -p "Use start-implementation for task T<n>"` |
| Follows `pr-create` skill to open PR | `pr-create` runs naturally inside Claude Code — same skill, same path |
| Uses `GITHUB_TOKEN` from `.env` | Container receives `GITHUB_TOKEN` as env var |

The runtime's role shrinks to: bootstrap → claim → set up context → invoke `claude` → observe result.

## Agent CLAUDE.md design

The agent `CLAUDE.md` is the briefing note written into the container before `claude` is invoked. It must answer three questions for Claude Code: *who am I, what am I doing right now, and how do I behave in this environment.*

### Structure

```markdown
# Agent execution context

You are an automated agent running inside a container as part of a distributed engineering team.
You are not in an interactive session. A human is not watching. You must complete your work
autonomously and exit cleanly.

## Identity
- Agent email: <GIT_AUTHOR_EMAIL>
- Agent name: <GIT_AUTHOR_NAME>

## Your claimed task
- Workspace: <workspace_local_path>
- Feature: <feature_id>
- Task: <task_id> — <task_title>
- Implementation repo: <task_repo_local_path>
- Branch: <task_branch>

## What you must do
Follow the standard execution contract — do not deviate:

1. Run `/start-implementation` for task <task_id>.
   It will validate readiness, check out the branch, and log the start action.

2. Implement the task as described in the task file and the feature's technical design.
   Write code, run tests, iterate until tests pass and the implementation is complete.

3. Run `/pr-self-review` against your branch.
   If it surfaces blocking issues you cannot resolve, stop and mark the task blocked.

4. Run `/pr-create` to push the branch and open a pull request.
   This requires GITHUB_TOKEN — it is already set in your environment.

5. The task will be marked `in_review` by `pr-create`. You are done. Exit cleanly.

## Rules
- Do not ask for clarification. Make reasonable decisions and document them in commits.
- Do not mark the task `done`. That is a human action.
- Do not modify `status.yaml` or any other feature's files.
- If you are blocked (budget, repeated failure, ambiguous spec), set the task to `blocked`
  with a clear `blocked_reason` and a `suggested_next_step`, then exit.
- Use the SSH key already configured in your environment for all git operations.
```

### How it is injected

The runtime writes this file to a temporary path (e.g. `/tmp/agent-claude.md`) and passes it to `claude` via the appropriate flag or working directory convention. The workspace's own `CLAUDE.md` (shared team rules, coding standards) is preserved and also read by Claude Code — the agent context is additive, not a replacement.

The agent `CLAUDE.md` is generated fresh per activation from the claimed task's metadata. It is never committed to any repo.

## Open questions

1. ~~Should the agent `CLAUDE.md` be merged with the workspace's existing `CLAUDE.md`?~~ **Closed.** The agent only ever writes to the task YAML (`T<n>.yaml`) and the task log. It never touches the workspace `CLAUDE.md` or any other workspace file. The agent context is written fresh to a temp path per activation and passed to `claude` as a separate input — the workspace `CLAUDE.md` (shared team rules, coding standards) is read by Claude Code alongside it and is never mutated.

2. **Token burn prevention — mechanism TBD in technical design.** The goal is clear: the agent must not accidentally consume unbounded tokens. The v1 raw SDK loop had a hard token cap (`budget.max_tokens_per_task`). Claude Code CLI offers `--max-turns` (turn count, not token count — approximate). The technical design must decide how to honour `agent.yaml` `budget.max_tokens_per_task` against a Claude Code subprocess — options include mapping it to `--max-turns`, parsing token counts from Claude Code's output stream, or a lightweight wrapper that kills the subprocess when a threshold is crossed. **The non-negotiable requirement: an agent must never silently exceed its declared token budget.**

3. ~~Exit code or task YAML state?~~ **Closed.** After `claude` exits, the runtime reads the task YAML to determine the outcome. Both `in_review` and `blocked` are valid terminal states for an activation cycle — `in_review` means the task completed and a PR was opened; `blocked` means the agent could not proceed (budget, iteration cap, self-review failure, ambiguous spec). Exit code is a secondary signal used only to detect a crash before any task state was written.
