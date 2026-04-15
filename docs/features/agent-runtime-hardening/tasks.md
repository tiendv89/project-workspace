# Tasks — agent-runtime-hardening

> Feature status: `in_tdd` — technical design approved 2026-04-15.
> Task stage: **draft** — awaiting human approval.
>
> Narrative (description + required skills + subtasks) lives in this file. Machine-readable state (status, deps, branch, log, PR) lives per-task in `tasks/T<n>.yaml`. Agents mutate only the YAML files; this document stays stable unless scope changes.
>
> All tasks target the `workflow` repo (`agent-runtime/` subdirectory). All tasks require `typescript-best-practices`.

---

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | SSH_PRIVATE_KEY env var delivery — main.ts + all orchestration templates | — |
| T2 | 1 | Bootstrap implementation repo cloning + env var population | — |
| T3 | 1 | Dockerfile claude CLI install + GITHUB_TOKEN docs | — |
| T4 | 1 | Agent context generator — src/bootstrap/agent-context.ts | — |
| T5 | 2 | run-claude.ts + main.ts wiring (Claude Code subprocess invocation) | T3, T4 |
| T6 | 3 | Delete orphaned modules + integration smoke test | T5 |

Wave numbers reflect the earliest wave each task can start. T1–T4 are fully independent and can run in parallel. T5 cannot start until T3 (claude in image) and T4 (agent-context.ts available to import). T6 must be last — deleting files before T5 is wired breaks compilation.

---

## T1 — SSH_PRIVATE_KEY env var delivery — main.ts + all orchestration templates

### Description
Closes Gap 1: SSH private key must be deliverable via environment variable for K8s, GitHub Actions, and other CI systems. Currently the key can only be provided as a file path (`SSH_KEY_PATH`).

**Design decision D1 (chosen C):** If `SSH_PRIVATE_KEY` is set, write the raw PEM content to `/tmp/agent_id_rsa` (mode `0o400`) at startup, use that path as `sshKeyPath`. Fall back to `SSH_KEY_PATH` if `SSH_PRIVATE_KEY` is not set. If neither is set, emit a warning and proceed with `sshKeyPath = undefined` (SSH-only repos will fail at clone time; HTTPS repos continue to work).

Update all orchestration templates to reflect the new env var delivery model:
- `docker-compose.yml`: dev agents and supervisor use `SSH_PRIVATE_KEY` passthrough (both `SSH_PRIVATE_KEY` and `SSH_KEY_PATH` supported simultaneously — D1 resolution picks whichever is set)
- `github-actions/scheduled.yml`: drop the "Write SSH key" file-staging step; pass `-e SSH_PRIVATE_KEY` directly to `docker run`
- `kubernetes/cronjob.yaml`: `SSH_PRIVATE_KEY` from Secret as env var; remove `agent-ssh` volume and volumeMount
- `systemd/agent-runtime.service`: `-e SSH_PRIVATE_KEY` passthrough; remove SSH volume mount

This task intentionally does NOT add `GITHUB_TOKEN` to any file — that is T3's scope. The two tasks touch overlapping files but different sections, so conflicts are trivial to resolve.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] `src/main.ts`: after reading env vars, add SSH resolution block — if `SSH_PRIVATE_KEY` is set, `writeFileSync("/tmp/agent_id_rsa", key, { mode: 0o400 })` and set `sshKeyPath = "/tmp/agent_id_rsa"`; else use `process.env.SSH_KEY_PATH`; else emit `warn_no_ssh_key` and set `sshKeyPath = undefined`.
- [ ] `DOCKER.md`: update "Optional environment variables" table — add `SSH_PRIVATE_KEY` row; update "Volume mounts" table — mark `/agent/ssh/` as optional (only needed when using `SSH_KEY_PATH` file-mount). Update the `docker run` example to show `SSH_PRIVATE_KEY` as preferred.
- [ ] `orchestration/.env.example`: add `# SSH_PRIVATE_KEY=<raw PEM content>` comment block under Optional, explaining it as the preferred alternative to `SSH_KEY_DIR`.
- [ ] `orchestration/docker-compose.yml`: add `SSH_PRIVATE_KEY: "${SSH_PRIVATE_KEY:-}"` to the shared `x-agent` base and the supervisor service's environment block and inner `docker run` command.
- [ ] `orchestration/github-actions/scheduled.yml`: remove the "Write SSH key" step; add `-e SSH_PRIVATE_KEY="${{ secrets.AGENT_SSH_KEY }}"` to the docker run command; remove `-v ~/.ssh:/agent/ssh:ro` and `-e SSH_KEY_PATH` from the docker run command. Update the "Required repository secrets" comment to reflect that `AGENT_SSH_KEY` is now delivered as env var.
- [ ] `orchestration/kubernetes/cronjob.yaml`: add `SSH_PRIVATE_KEY` to Secret `stringData`; add `SSH_PRIVATE_KEY` env var from secretKeyRef in the CronJob container spec; remove `SSH_KEY_PATH` env var, `agent-ssh` volume, and the corresponding volumeMount.
- [ ] `orchestration/systemd/agent-runtime.service`: add `-e SSH_PRIVATE_KEY` to ExecStart docker run command; remove `-v /etc/agent-runtime/ssh:/agent/ssh:ro` and `-e SSH_KEY_PATH`. Update the EnvironmentFile comment to document `SSH_PRIVATE_KEY`.
- [ ] `QUICKSTART.md`: update SSH key setup step — present `SSH_PRIVATE_KEY` as the preferred method; retain `SSH_KEY_PATH` as the file-mount alternative.
- [ ] Acceptance: `main.ts` compiles cleanly; manually verify the SSH resolution logic handles all three cases (env var set, file path set, neither set).

---

## T2 — Bootstrap implementation repo cloning + env var population

### Description
Closes Gap 2: bootstrap currently only clones the management repo. After this task, `bootstrap.ts` reads `workspace.yaml` from each cloned management repo, finds every non-management repo in `repos[]`, clones or pulls each one into `workspacesRoot/<repo-name>`, and sets `process.env[VAR]` for every `local_path: env:<VAR>` declaration.

**Design decision D2 (chosen A):** Clone path is `join(workspacesRoot, extractRepoName(repo.github))` — consistent with the existing fallback in `resolveRepoLocalPath`.

**Management repo filtering:** Skip any `repos[]` entry whose `github` URL matches a URL in `agent.yaml watches[]` — those are already cloned in the management-repo step.

**Branch selection:** Use `repo.base_branch ?? workspaceBaseBranch` as the branch for `syncRepo`.

Side effect on `src/main.ts`: `resolveRepoLocalPath` is simplified (not deleted) — the fallback path (`join(workspacesRoot, extractRepoName(...))`) is removed since bootstrap now guarantees `process.env[VAR]` is set. The simplified function reads `workspace.yaml`, finds `env:<VAR>`, and returns `process.env[VAR]` (throws if missing).

### Required skills
- typescript-best-practices

### Subtasks
- [ ] `src/bootstrap/bootstrap.ts`: add `import { parse as parseYaml } from "yaml"` at the top (yaml is already a declared dependency).
- [ ] After step 5 (management repo cloned/pulled), read `<managementRepoLocalPath>/workspace.yaml`. If absent or has no `repos[]`, skip silently (non-fatal).
- [ ] Parse `repos[]`, filter out entries whose `github` URL matches any entry in `agent.yaml watches[]`.
- [ ] For each remaining impl repo: derive `localPath = join(workspacesRoot, extractRepoName(repo.github))`; use `repo.base_branch ?? workspaceBaseBranch` as branch; call existing `syncRepo`; emit `workspace_cloned` / `workspace_pulled` with `workspace_url: repo.github`. On failure: emit `bootstrap_failed` with `reason: "git_impl_repo_sync_failed"`, return exit code 3.
- [ ] After `syncRepo`: if `repo.local_path?.startsWith("env:")`, extract the var name and `process.env[varName] = localPath`.
- [ ] `src/main.ts`: simplify `resolveRepoLocalPath` — remove the fallback `join(workspacesRoot, extractRepoName(...))` branch; throw if `process.env[VAR]` is missing after bootstrap guarantees it.
- [ ] Unit test: given a mock `workspace.yaml` with one management repo (matching a `watches[]` URL) and one impl repo, assert (a) impl repo's `syncRepo` is called with the correct path and branch, (b) `process.env[VAR]` is set. Given absent `workspace.yaml`, assert bootstrap completes without error.
- [ ] Acceptance: `runBootstrap` in the integration test harness populates `process.env[VAR]` for a test workspace with a declared impl repo.

---

## T3 — Dockerfile claude CLI install + GITHUB_TOKEN docs

### Description
Closes Gap 3 (infrastructure side): the Docker image must have the Claude Code CLI (`claude`) available so `run-claude.ts` can invoke it. Also declares `GITHUB_TOKEN` as a required env var across all documentation and orchestration templates — it is needed by the `pr-create` skill inside Claude Code to call the GitHub REST API.

This task intentionally does NOT add `SSH_PRIVATE_KEY` to orchestration files — that is T1's scope. Conflicts with T1 are isolated to different sections.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] `Dockerfile`: add `RUN npm install -g @anthropic-ai/claude-code` after the Node.js layer. Add a comment block listing `GITHUB_TOKEN` as a required env var alongside `ANTHROPIC_API_KEY`.
- [ ] `DOCKER.md`: add `GITHUB_TOKEN` row to the "Required environment variables" table with description "GitHub personal access token — used by `pr-create` to call the GitHub REST API".
- [ ] `orchestration/.env.example`: add `GITHUB_TOKEN=ghp_...` under Required, with a comment explaining it is needed for `pr-create`.
- [ ] `orchestration/docker-compose.yml`: add `GITHUB_TOKEN: "${GITHUB_TOKEN}"` to the shared `x-agent` base environment block, both dev agent environment overrides, and the supervisor service environment block and inner `docker run` command.
- [ ] `orchestration/github-actions/scheduled.yml`: add `GITHUB_TOKEN` to the "Required repository secrets" comment; add `-e GITHUB_TOKEN="${{ secrets.GITHUB_TOKEN }}"` (or `secrets.AGENT_GITHUB_TOKEN` if GHA's built-in `GITHUB_TOKEN` is insufficient) to the `docker run` step.
- [ ] `orchestration/kubernetes/cronjob.yaml`: add `GITHUB_TOKEN` to Secret `stringData`; add `GITHUB_TOKEN` env var from secretKeyRef in the CronJob container spec.
- [ ] `orchestration/systemd/agent-runtime.service`: add `-e GITHUB_TOKEN` to ExecStart docker run command passthrough. Update EnvironmentFile comment.
- [ ] `QUICKSTART.md`: add `GITHUB_TOKEN` to the "required env vars" checklist.
- [ ] Acceptance: `docker build` succeeds and `docker run --rm <image> claude --version` exits 0.

---

## T4 — Agent context generator — src/bootstrap/agent-context.ts

### Description
Pure new module. Exports a single pure function `generateAgentContext` that returns the per-activation agent CLAUDE.md string. No file I/O — the caller writes it wherever it chooses; tests can assert on the returned string directly.

The generated string follows the product spec's agent CLAUDE.md design: identity, claimed task, execution sequence (`/start-implementation` → work → `/pr-self-review` → `/pr-create`), behavioral rules for headless operation, and an explicit `## Model` directive (`Use model: <implementationModel>`) derived from `workspace.yaml` model policy via `resolve-model-policy.ts`.

This is a Wave 1 task (no dependencies). T5 depends on it.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Create `src/bootstrap/agent-context.ts` exporting:
  ```ts
  generateAgentContext(opts: {
    taskId: string;
    featureId: string;
    taskTitle: string;
    taskBranch: string;
    taskRepo: string;
    taskRepoRoot: string;
    workspaceRoot: string;
    gitAuthorEmail: string;
    gitAuthorName: string;
    implementationModel: string;
  }): string
  ```
- [ ] The returned string must include, in order: (1) preamble — agent is automated, no interactive session; (2) `## Identity` — agent email + name; (3) `## Your claimed task` — workspace, feature, task ID + title, impl repo, branch; (4) `## What you must do` — `/start-implementation` → implement → `/pr-self-review` → `/pr-create` sequence; (5) `## Model` — `Use model: <implementationModel>`; (6) `## Rules` — no clarification requests, do not mark done, do not modify status.yaml or other feature files, set blocked with reason/suggested_next_step if stuck.
- [ ] Unit test: call `generateAgentContext` with known inputs; assert the returned string contains `taskId`, `featureId`, `taskBranch`, `workspaceRoot`, `gitAuthorEmail`, `gitAuthorName`, and `implementationModel` in the appropriate sections. Assert it does NOT contain `undefined` or `null` anywhere.
- [ ] Acceptance: unit tests pass; `tsc --noEmit` on the module passes.

---

## T5 — run-claude.ts + main.ts wiring (Claude Code subprocess invocation)

### Description
The core architectural change: replaces the 800-line raw Anthropic SDK tool-use loop (`run-task.ts`) with a thin subprocess invocation of the Claude Code CLI. After this task, the agent invokes `claude -p "<agentContext>" --max-turns <maxTurns>` as a child process, then reads the task YAML state to determine outcome.

**Depends on T3** (claude binary must exist in the image for the call to work) and **T4** (agent-context.ts must exist to import).

**Token audit (D3 option X):** After `spawnSync`, inspect the captured stdout for Claude Code's usage JSON line. If found, extract total tokens and write to `task.execution.tokens_used`. If the format is not found or unstable, fall back to option Y (emit `budget_audit_skipped` and skip the check). Implementer must verify the exact stdout format before coding the parse path.

`main.ts` changes: keep `loadWorkspaceModelPolicy` (still needed to derive `implementationModel` for `generateAgentContext`); add `runClaude` import; remove `runTask` and `openLogSink` imports and calls.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Create `src/loop/run-claude.ts` exporting:
  ```ts
  runClaude(opts: {
    taskId: string;
    featureId: string;
    workspaceRoot: string;
    taskRepoRoot: string;
    agentContext: string;
    maxTurns: number;
    maxTokens: number;
    sshKeyPath: string | undefined;
    gitAuthorEmail: string;
  }): Promise<RunClaudeResult>
  type RunClaudeResult =
    | { outcome: "in_review" }
    | { outcome: "blocked"; reason: string; details?: unknown }
  ```
- [ ] Internally: use `spawnSync` with args array `["claude", "-p", agentContext, "--max-turns", String(maxTurns)]` and `cwd: taskRepoRoot`, `env: { ...process.env, GIT_SSH_COMMAND: sshKeyPath ? \`ssh -i ${sshKeyPath} -o StrictHostKeyChecking=no\` : undefined }`.
- [ ] After subprocess exit: read task YAML from `<workspaceRoot>/docs/features/<featureId>/tasks/<taskId>.yaml`. Determine outcome from `task.status`: `in_review` → success; `blocked` → check token overage; still `in_progress` → write `blocked` with `runtime_error`.
- [ ] Token audit: inspect captured stdout for usage JSON. If present, parse total tokens; if > `maxTokens`, override `blocked_reason` to `budget_exceeded`. If stdout format not found, emit `budget_audit_skipped` event and skip.
- [ ] `src/main.ts`: add `writeFileSync` import; add SSH resolution block (see T1 for spec); add `generateAgentContext` + `runClaude` imports; after claim, call `loadWorkspaceModelPolicy`, resolve `implementationModel` via `resolveModelPolicy(workspaceModelPolicy, taskModelOverrides, "implementation")`, call `generateAgentContext`, then `runClaude`. Remove `runTask` and `openLogSink` calls. Keep `loadWorkspaceModelPolicy` and simplified `resolveRepoLocalPath` (see T2).
- [ ] Ensure `tsc --noEmit` passes across the whole project after changes (run-task.ts is still present at this stage — do not delete it here; T6 handles deletion).
- [ ] Acceptance: `tsc --noEmit` passes; the full activation sequence (bootstrap → eligibility → claim → run-claude → outcome) is traceable through the code without any dead or unreachable branches.

---

## T6 — Delete orphaned modules + integration smoke test

### Description
Final cleanup wave. Deletes `run-task.ts` and the two modules it exclusively owned (`suggested-next-step.ts`, `log-sink.ts`), removes all their imports, and verifies the project still compiles and passes the integration smoke test.

**Must be last** — deleting these files before T5 wires in `run-claude.ts` would break compilation.

The integration smoke test: build the image; run the container against a test workspace that has a pre-claimed `in_progress` task; the `claude` binary is replaced with a stub script that writes a minimal `in_review` status to the task YAML and exits 0. Assert the container exits 0.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Delete `src/loop/run-task.ts`.
- [ ] Delete `src/claim/suggested-next-step.ts`.
- [ ] Delete `src/logging/log-sink.ts`.
- [ ] Remove all `import` statements referencing the deleted modules from `src/main.ts` and any other file that still imports them. Run `grep -r "run-task\|suggested-next-step\|log-sink" src/` to confirm no stale references.
- [ ] Run `tsc --noEmit` — must pass with zero errors.
- [ ] Run existing test suite — must pass.
- [ ] Write integration smoke test: create a minimal test workspace fixture with a pre-claimed `in_progress` task YAML; create a stub `claude` script that writes `status: in_review` to the task YAML and exits 0; run the container with `CLAUDE_BIN` override or PATH override; assert container exits 0 and task YAML reads `status: in_review`.
- [ ] Acceptance: `tsc --noEmit` passes, all tests pass, smoke test passes; `grep -r "run-task\|suggested-next-step\|log-sink" src/` returns empty.
