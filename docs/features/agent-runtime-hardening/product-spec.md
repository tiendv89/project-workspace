# Product Specification

## Feature
- Feature ID: `agent-runtime-hardening`
- Title: Agent runtime hardening — credential delivery, full bootstrap, and PR lifecycle

## Problem

The distributed-agent-team v1 runtime (`agent-runtime/`) is functionally complete but has three gaps that prevent reliable production use:

**Gap 1 — SSH credential delivery is file-mount only.**
`bootstrap.ts` and every git operation resolve the SSH key from a file path (`SSH_KEY_PATH`). This works in Docker Compose (host `~/.ssh` is volume-mounted) but is awkward in Kubernetes (requires a Secret-backed volume) and impossible in GitHub Actions (secrets are env vars, not files). There is no way to pass the key as an environment variable.

**Gap 2 — Bootstrap only clones the management repo.**
`bootstrap.ts` clones the repos listed in `agent.yaml` `watches:` (the management repo). It does not read `workspace.yaml` inside that repo or clone the implementation repos declared there (`repos[]`). When `run-task.ts` resolves `taskRepoRoot` at runtime, those repos may not exist on disk, causing the task to fail immediately. Additionally, `workspace.yaml` declares `local_path: env:<VAR>` for each repo but nothing ever sets those env vars — the runtime silently falls back to a path that may not exist.

**Gap 3 — No PR is created after task completion.**
The tool-use loop ends at `git push` (branch pushed to origin) and marks the task `in_review`. A human must then manually open a pull request. The `gh` CLI is not installed in the image, `GITHUB_TOKEN` is not a documented input, and there is no runtime step that calls `gh pr create`. The branch lives on GitHub with no PR attached.

## Goals

1. **SSH key deliverable via environment variable.** Operators can pass `SSH_PRIVATE_KEY` (raw PEM content) as an env var. The runtime writes it to a `0400` temp file at startup and uses it for all git operations. `SSH_KEY_PATH` (file path) remains supported as a fallback. This makes credential delivery consistent across Docker Compose, Kubernetes, GitHub Actions, and any other runner.

2. **`gh` CLI bundled in the image.** The GitHub CLI is installed in the Docker image via the official apt repo so that the agent can call `gh pr create` from the `bash` tool or from the runtime directly.

3. **`GITHUB_TOKEN` is a documented, threaded input.** The token is declared in `.env.example`, the K8s Secret manifest, and `DOCKER.md`. It is passed into the container environment and reaches every `bash` tool invocation automatically.

4. **Bootstrap clones all repos declared in `workspace.yaml`.** After cloning the management repo, `bootstrap.ts` reads `workspace.yaml`, finds every repo in `repos[]` that is not the management repo itself, and clones or pulls each one into `workspacesRoot` at a predictable path (`join(workspacesRoot, repoName)`). Bootstrap is the single place responsible for ensuring all repos are present before any task runs.

5. **Bootstrap populates repo local-path env vars.** For each repo whose `workspace.yaml` entry declares `local_path: env:<VAR>`, bootstrap sets `process.env[VAR]` to the resolved path after cloning. This means `resolveRepoLocalPath` in `main.ts` always finds the value via the env var lookup — no silent fallback required.

6. **PR is automatically created after task completion.** When the tool-use loop ends successfully and `markTaskInReview` is called, the runtime calls `gh pr create` for the task's implementation repo. Title comes from `task.title`, base branch from `workspace.yaml` `repos[].base_branch`. Failure is non-fatal: if `GITHUB_TOKEN` is absent or the call fails, a `pr_create_failed` event is emitted and the task still returns `in_review`.

## Non-goals

1. HTTPS-based git authentication — the runtime remains SSH-only for repo sync; `GITHUB_TOKEN` is used only for the GitHub API via `gh`.
2. Multi-key support — one SSH key covers all repos in the workspace.
3. PR templates, reviewers, labels, or other advanced PR metadata — a plain title + body is sufficient for v1 PR creation.
4. Automatic PR merging — the agent opens the PR; a human approves and merges.
5. Retrying failed PR creation — one attempt per task run; the next activation can retry if needed.

## User stories

1. **As an operator deploying to Kubernetes**, I can store the SSH private key in a K8s Secret and inject it as `SSH_PRIVATE_KEY` env var — no volume mount configuration required.
2. **As an operator using GitHub Actions**, I can pass `SSH_PRIVATE_KEY: ${{ secrets.SSH_KEY }}` directly to the container without any file staging step.
3. **As an operator**, I add `GITHUB_TOKEN` to my `.env` (or K8s Secret) once and every agent activation can open PRs automatically.
4. **As a tech lead**, I can add a new implementation repo to `workspace.yaml` and the agent will clone it and set its local path env var on next bootstrap — no manual env var configuration needed.
5. **As a developer reviewing agent output**, I see a PR appear in GitHub automatically when the agent finishes a task — I do not need to find the branch and open it manually.

## Open questions

1. Should `pr_create_failed` be a terminal blocking reason (task goes to `blocked`) or truly non-fatal (task stays `in_review`)? For now: non-fatal, since the branch is pushed and the code is complete.
2. Should bootstrap failure on an implementation repo clone be fatal (exit 3) or should the agent proceed and let the task fail at runtime? For now: fatal — a missing repo is a configuration error, not a transient one.
