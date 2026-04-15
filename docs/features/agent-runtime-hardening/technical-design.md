# Technical Design

## Feature
- Feature ID: `agent-runtime-hardening`
- Title: Agent runtime hardening — Claude Code environment, full bootstrap, and credential delivery

## Current State

### What exists

| File | Lines | Role |
|---|---|---|
| `src/main.ts` | 296 | Entry point: reads env, runs bootstrap → eligibility → claim → runTask |
| `src/bootstrap/bootstrap.ts` | 405 | Clones management repo + workflow repo, audits skills |
| `src/claim/claim-task.ts` | 294 | Git-based atomic task claim with SHA contention |
| `src/loop/run-task.ts` | 1067 | Raw Anthropic SDK tool-use loop (bash, file r/w, git ops) |
| `src/claim/suggested-next-step.ts` | ~100 | Generates Haiku-tier triage hint on blocked tasks |
| `src/logging/log-sink.ts` | 249 | Per-run JSONL log writer with git push |
| `src/config/resolve-model-policy.ts` | ~80 | Merges workspace + task model policy |
| `src/config/parse-model-overrides.ts` | ~60 | Parses `### Model overrides` from tasks.md |
| `src/config/validate-agent-yaml.ts` | 141 | AJV schema validation for agent.yaml |
| `src/eligibility/match.ts` | ~100 | Pure-code eligibility scan |
| `src/eligibility/parse-tasks-md.ts` | ~80 | Parses required skills + model overrides from tasks.md |
| `src/types/task.ts` | ~60 | Task YAML TypeScript type |

### What does not exist
- `SSH_PRIVATE_KEY` env var support — key must arrive via file mount
- Implementation repo cloning in bootstrap — only management repo is cloned
- `process.env[VAR]` population for `local_path: env:<VAR>` repos
- Claude Code CLI (`claude`) in the Docker image
- `GITHUB_TOKEN` as a declared required input
- Agent context generator (the briefing CLAUDE.md written per activation)

### Things we keep vs. replace

| Keep (unchanged) | Keep (used by new code) | Replace / delete | Add new |
|---|---|---|---|
| `claim-task.ts` | `resolve-model-policy.ts` | `run-task.ts` → deleted | `src/loop/run-claude.ts` |
| `eligibility/match.ts` | `parse-model-overrides.ts` | `suggested-next-step.ts` → deleted | `src/bootstrap/agent-context.ts` |
| `eligibility/parse-tasks-md.ts` | | `logging/log-sink.ts` → deleted | |
| `validate-agent-yaml.ts` | | | |
| `types/task.ts` | | | |
| `bootstrap.ts` (extended) | | | |
| `main.ts` (modified) | | | |

## Constraints

From product spec (non-negotiable):

1. SSH key must be deliverable via `SSH_PRIVATE_KEY` env var (raw PEM) in addition to file path.
2. Bootstrap must clone all repos in `workspace.yaml` `repos[]` and set their `local_path` env vars.
3. The container must be a Claude Code environment — `claude` CLI invoked after claim.
4. An agent-specific `CLAUDE.md` is written per activation and passed as the `-p` prompt — the workspace `CLAUDE.md` is never mutated.
5. `GITHUB_TOKEN` is a required env var — needed by `pr-create` inside Claude Code.
6. The agent must never silently exceed its declared `budget.max_tokens_per_task`.
7. Eligibility matching, bootstrap, and claim remain zero-LLM-token operations.
8. The agent only writes to task YAML files and task logs — no other workspace files.

## Options Considered

### D1 — SSH key delivery

**Options:**
- **A. File path only (current)** — `SSH_KEY_PATH` points to a file already present in the container.
- **B. Env var only** — `SSH_PRIVATE_KEY` contains raw PEM; no file path support.
- **C. Env var with file path fallback** — if `SSH_PRIVATE_KEY` is set, write it to a `0400` temp file at startup and use that as `sshKeyPath`. Fall back to `SSH_KEY_PATH` if not set.

**Chosen: C.** Env var is preferred for K8s/CI; file path preserved for Docker Compose. Single resolution point in `main.ts` at startup; all downstream callers (`bootstrap.ts`, `claim-task.ts`, and the new `run-claude.ts`) continue to receive a file path unchanged.

---

### D2 — Implementation repo cloning location

After reading `workspace.yaml` in bootstrap, where should implementation repos be cloned?

**Options:**
- **A. `join(workspacesRoot, extractRepoName(repo.github))`** — predictable path derived from repo name, same fallback already used by `resolveRepoLocalPath` in `main.ts`.
- **B. Configurable per repo via `workspace.yaml`** — use `local_path` value if it is a literal path (not `env:<VAR>`).
- **C. Always use `join(workspacesRoot, repo.id)`** — use the `id` field instead of repo name.

**Chosen: A.** Consistent with the existing fallback in `resolveRepoLocalPath`. No new config surface. If `local_path: env:<VAR>` is declared, bootstrap sets `process.env[VAR]` to this same derived path after cloning — so both lookup paths converge.

---

### D3 — Token budget enforcement against `claude` subprocess

`budget.max_tokens_per_task` is a token count. Claude Code CLI offers `--max-turns` (a turn count). These are different.

**Options:**
- **A. `--max-turns` = `budget.max_iterations`** — use turn count as the only guard. Tokens are not directly controlled.
- **B. Stream stdout, parse Claude Code token events, kill subprocess when threshold crossed** — real-time hard cap. Complex; depends on Claude Code output format stability.
- **C. `--max-turns` as primary loop guard + post-exit token audit** — after `claude` exits, read the token counts written to the task log by `start-implementation`. If total > `budget.max_tokens_per_task`, mark the task `blocked` with `blocked_reason: budget_exceeded`. Overshoot is detected and blocked, not silently absorbed.
- **D. Dynamic `--max-turns` from token heuristic** — compute `ceil(max_tokens / K)` where K is an assumed tokens-per-turn constant (e.g. 3 000). Gives `--max-turns` a token-grounded value.

**Chosen: A + C combined.** `--max-turns` = `budget.max_iterations` (prevents runaway loops). After exit, the runtime reads the task YAML log written by `start-implementation` for token counts and enforces the token cap post-hoc. Both guards together satisfy the "must not silently exceed" requirement: turns cap catches infinite loops; token audit catches budget overruns and blocks the task before it can be re-queued.

---

### D4 — Agent context injection into Claude Code

How does the per-activation task briefing reach Claude Code?

**Options:**
- **A. Write to temp file, pass as the `-p` prompt content** — agent context is the entire `-p` string. Claude Code reads the workspace `CLAUDE.md` from the cwd automatically alongside it.
- **B. Write to `CLAUDE.md` in the implementation repo working directory** — simple, but mutates a tracked file in the repo. Unacceptable.
- **C. Write to a temp directory, symlink workspace `CLAUDE.md` there, set as cwd** — hermetic but complex; adds a symlink layer.
- **D. Write to a temp directory as `CLAUDE.md`, invoke `claude` with that as an additional config path** — if Claude Code supports a `--config-dir` or equivalent flag.

**Chosen: A.** The `-p` prompt is the task briefing. The workspace `CLAUDE.md` (shared team rules, coding standards) is read automatically by Claude Code from the implementation repo's cwd. The two are additive. No files are mutated in any repo.

---

### D5 — What happens to run-task.ts and its dependencies

**Options:**
- **A. Keep run-task.ts as a fallback mode** — add an `AGENT_MODE=claude_code|sdk` env var toggle.
- **B. Delete run-task.ts and the modules it exclusively owns** — clean break. Removes `suggested-next-step.ts` and `log-sink.ts`. `resolve-model-policy.ts` and `parse-model-overrides.ts` are retained because the new `agent-context.ts` uses them to pre-resolve the implementation model from `workspace.yaml` and embed the model directive in the agent CLAUDE.md prompt.
- **C. Keep but disable** — comment out, leave as dead code.

**Chosen: B.** The product spec is explicit: `run-task.ts` is replaced, not toggled. Dead code in a runtime is a maintenance burden. `suggested-next-step.ts` is deleted (Claude Code + agent CLAUDE.md handles triage hints natively). `log-sink.ts` is deleted (task YAML log entries written by skills provide the audit trail). `resolve-model-policy.ts` and `parse-model-overrides.ts` are **kept** — `agent-context.ts` calls them to pre-resolve the implementation model and write an explicit model directive into the agent CLAUDE.md, ensuring `workspace.yaml` model policy is honoured even when delegating execution to Claude Code CLI.

---

## Chosen Design

### Architecture after this feature

```
Container starts
  main.ts
  ├── resolve SSH key (SSH_PRIVATE_KEY → temp file, or SSH_KEY_PATH)   [D1]
  ├── bootstrap.ts
  │   ├── validate agent.yaml
  │   ├── clone/pull workflow repo
  │   ├── clone/pull management repo (from agent.yaml watches[])
  │   ├── read workspace.yaml from management repo                       [D2]
  │   ├── clone/pull each implementation repo → workspacesRoot/<name>
  │   ├── set process.env[VAR] for each local_path: env:<VAR> repo
  │   └── skill reference audit (unchanged)
  ├── eligibility scan (unchanged — pure code, zero LLM)
  ├── claim-task.ts (unchanged)
  └── run-claude.ts                                                       [D3, D4]
      ├── generate agent context string (agent-context.ts)
      ├── spawnSync: ["claude", "-p", agentContext, "--max-turns", String(maxTurns)]
      │     cwd: taskRepoRoot
      │     env: { ...process.env, GIT_SSH_COMMAND: ... }
      │     (args array — no shell interpolation, no injection risk)
      ├── on exit: read task YAML to determine outcome
      ├── if outcome == in_review → emit task_run_complete, exit 0
      ├── if outcome == blocked → check token count, emit, exit 0
      └── if task YAML unchanged (crash before start-implementation) → mark blocked
```

### New module: `src/bootstrap/agent-context.ts`

Exports a single pure function:

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
  implementationModel: string;   // pre-resolved by caller via resolve-model-policy.ts
}): string
```

Returns the full CLAUDE.md string following the design in the product spec: identity, claimed task, execution sequence (`/start-implementation` → work → `/pr-self-review` → `/pr-create`), behavioral rules for headless operation, and an explicit `## Model` directive (`Use model: <implementationModel>`) so the `workspace.yaml` model policy is honoured even when delegating execution to Claude Code CLI.

No file I/O — the caller resolves the model and passes it in; the caller writes the returned string wherever it chooses (tests can assert on the string directly).

### New module: `src/loop/run-claude.ts`

Exports:

```ts
runClaude(opts: {
  taskId: string;
  featureId: string;
  workspaceRoot: string;
  taskRepoRoot: string;
  agentContext: string;        // from agent-context.ts
  maxTurns: number;            // budget.max_iterations
  maxTokens: number;           // budget.max_tokens_per_task — for post-exit audit
  sshKeyPath: string | undefined;
  gitAuthorEmail: string;
}): Promise<RunClaudeResult>
```

Where `RunClaudeResult` mirrors the existing `RunTaskResult`:
```ts
type RunClaudeResult =
  | { outcome: "in_review" }
  | { outcome: "blocked"; reason: string; details?: unknown }
```

Internally:
1. Invokes `["claude", "-p", agentContext, "--max-turns", String(maxTurns)]` via `spawnSync` with `cwd: taskRepoRoot`. Uses an args array (not a shell string) — no interpolation, no injection risk.
2. After exit, reads task YAML. Task state drives outcome — not exit code.
3. If task is `in_review` → `{ outcome: "in_review" }`.
4. If task is `blocked` → check `task.execution.tokens_used` (see token audit note below); if field is present and total > `maxTokens`, override `blocked_reason` to `budget_exceeded`; return `{ outcome: "blocked", reason: task.blocked_reason }`.
5. If task is still `in_progress` (crash before any state write) → write `blocked` with `runtime_error`, return blocked.

**Token audit note:** `TaskExecution` currently has no `tokens_used` field. Two options for implementation:
- **Option X (preferred):** Parse Claude Code's structured stdout — `spawnSync` captures it; look for the JSON usage line Claude Code emits at session end. Write the total to `task.execution.tokens_used` before writing the outcome.
- **Option Y (fallback):** Skip token audit if no field is present; `--max-turns` remains the only hard cap. Log a `budget_audit_skipped` event.

**Chosen: X.** Implementer must verify the exact stdout format Claude Code uses for usage reporting before coding this path. If the format is unstable or absent, fall back to Y and open a follow-up to add explicit skill-side token reporting.

### Modified: `src/main.ts`

Changes:
- Add `writeFileSync` import.
- After reading env vars: resolve `SSH_PRIVATE_KEY` → write to `/tmp/agent_id_rsa` (0400), set `sshKeyPath`. If neither `SSH_PRIVATE_KEY` nor `SSH_KEY_PATH` is set, emit a warning and proceed with `sshKeyPath = undefined` (management repos declared with HTTPS will still work; SSH-only repos will fail at clone time).
- Remove `runTask` and `openLogSink` imports and calls.
- Add `runClaude` import. After claim, call `loadWorkspaceModelPolicy` (kept), resolve `implementationModel` via `resolveModelPolicy`, call `generateAgentContext`, then call `runClaude` with the returned string.
- **`loadWorkspaceModelPolicy` is kept** — it is called immediately before `generateAgentContext` to supply `implementationModel`. It is no longer passed to `runTask` (deleted), but it is still needed here.
- **`resolveRepoLocalPath` is simplified, not deleted.** After bootstrap guarantees `process.env[VAR]` is set for every `local_path: env:<VAR>` repo, the function no longer needs the fallback path (`join(workspacesRoot, extractRepoName(...))`). The simplified version reads `workspace.yaml`, finds the `env:<VAR>` declaration, and returns `process.env[VAR]` (throws if the var is not set — bootstrap is responsible for that invariant). The fallback branch is removed.

### Modified: `src/bootstrap/bootstrap.ts`

Changes:
- Add `import { parse as parseYaml } from "yaml"` (already imported in `main.ts`; bootstrap does not yet have it).
- After each management repo is cloned/pulled (step 5), read `<managementRepoLocalPath>/workspace.yaml`.
- Parse `repos[]`. Filter out entries whose `github` URL matches any URL already listed in `agent.yaml watches[]` (those are management repos — already cloned above, not cloned again).
- For each remaining implementation repo:
  - Derive `localPath = join(workspacesRoot, extractRepoName(repo.github))` (consistent with D2 decision).
  - Use `repo.base_branch ?? workspaceBaseBranch` as the branch argument to `syncRepo`.
  - Call `syncRepo(repo.github, localPath, branch, gitEnv)`.
  - Emit existing `workspace_cloned` / `workspace_pulled` events with `workspace_url: repo.github`.
  - If `repo.local_path?.startsWith("env:")`, extract the var name and set `process.env[VAR] = localPath`.
- On clone failure: emit `bootstrap_failed` with reason `git_impl_repo_sync_failed`, return exit code 3.
- If `workspace.yaml` is absent or has no `repos[]`: skip silently (non-fatal — management-only workspaces are valid).

### Modified: `Dockerfile`

Add after system packages:
```dockerfile
RUN npm install -g @anthropic-ai/claude-code
```

Add `GITHUB_TOKEN` to documented required env vars comment block.

### Modified: `DOCKER.md` and `orchestration/.env.example`

- `GITHUB_TOKEN` added as required env var (alongside `ANTHROPIC_API_KEY`).
- `SSH_PRIVATE_KEY` added as optional env var with description; `SSH_KEY_PATH` retained as file-mount fallback.

### Modified: `orchestration/docker-compose.yml`

- `GITHUB_TOKEN` added to both dev agent definitions (`agent-1`, `agent-2`) and the `supervisor` service environment block and its inner `docker run` command.
- `SSH_PRIVATE_KEY` added as a passthrough env var alongside the existing `SSH_KEY_PATH` file-mount. Both are supported simultaneously — `main.ts` D1 resolution picks whichever is set.

### Modified: `orchestration/github-actions/scheduled.yml`

- `GITHUB_TOKEN` added to required secrets list and passed via `-e GITHUB_TOKEN` to the docker run step.
- `SSH_PRIVATE_KEY` replaces the current "Write SSH key" step: instead of writing the secret to `~/.ssh/id_rsa` and volume-mounting `~/.ssh`, the key is passed as `-e SSH_PRIVATE_KEY="${{ secrets.AGENT_SSH_KEY }}"` directly to the container. `main.ts` writes it to `/tmp/agent_id_rsa` (0400) at startup. The SSH volume mount (`-v ~/.ssh:/agent/ssh:ro`) and `SSH_KEY_PATH` env var are removed from this step.
- `AGENT_SSH_KEY` secret remains the same secret name; its value (raw PEM) is now delivered as env var instead of file.

### Modified: `orchestration/kubernetes/cronjob.yaml`

- `GITHUB_TOKEN` added to the Secret `stringData` block.
- `SSH_PRIVATE_KEY` added to the Secret `stringData` block (raw PEM value).
- `SSH_PRIVATE_KEY` added as an env var in the CronJob container spec, sourced from the secret.
- `SSH_KEY_PATH` env var and the `agent-ssh` volume + volumeMount removed — key delivery is now env-var-only in K8s.

### Modified: `orchestration/systemd/agent-runtime.service`

- `GITHUB_TOKEN` and `SSH_PRIVATE_KEY` added to the `docker run` env var passthrough (`-e GITHUB_TOKEN -e SSH_PRIVATE_KEY`).
- SSH volume mount (`-v /etc/agent-runtime/ssh:/agent/ssh:ro`) and `-e SSH_KEY_PATH` removed from the ExecStart command.
- `EnvironmentFile` comment updated to document that `SSH_PRIVATE_KEY` (raw PEM, one line or escaped) and `GITHUB_TOKEN` must be added to `/etc/agent-runtime/env`.

### Modified: `QUICKSTART.md`

- Add `GITHUB_TOKEN` to the "required env vars" quick-start checklist.
- Replace the SSH key setup step (create file, set `SSH_KEY_PATH`) with: "set `SSH_PRIVATE_KEY` to the raw PEM content (preferred) or keep `SSH_KEY_PATH` pointing to the key file".
- Remove references to `run-task.ts` behaviour; describe the Claude Code subprocess model.

### Deleted files

| File | Reason |
|---|---|
| `src/loop/run-task.ts` | Replaced by `run-claude.ts` |
| `src/claim/suggested-next-step.ts` | Claude Code + agent CLAUDE.md handles triage hints natively |
| `src/logging/log-sink.ts` | Task YAML log entries written by skills provide the audit trail |

## Test Strategy

### Unit tests (new)
| Module | What to test |
|---|---|
| `agent-context.ts` | `generateAgentContext` returns a string containing taskId, featureId, taskBranch, workspaceRoot, gitAuthorEmail, and the implementationModel directive. Pure function — no mocks needed. |
| `main.ts` SSH resolution | Given `SSH_PRIVATE_KEY` set, verify temp file is written at `/tmp/agent_id_rsa` with mode `0o400`; given only `SSH_KEY_PATH`, verify it is used as-is; given neither, verify `sshKeyPath` is `undefined`. |

### Integration test (T6)
After T5 wiring, the existing integration test harness (if one exists) must pass with `run-claude.ts` in place of `run-task.ts`. If no harness exists, T6 must include a smoke test:
- Build the Docker image with `claude` CLI installed.
- Run the container against a test workspace with a pre-claimed `in_progress` task.
- Assert the container exits `0` and the task YAML reflects the expected terminal state.

The integration test does **not** need to run a real Claude Code session — the `claude` binary can be replaced with a stub script that writes a minimal `in_review` state to the task YAML and exits `0`.

### Bootstrap test (T2)
- Given a `workspace.yaml` with two repos (management + one impl), assert that after `runBootstrap` the impl repo is cloned at `join(workspacesRoot, repoName)` and `process.env[VAR]` is set.
- Given `workspace.yaml` absent, assert bootstrap completes without error.

## Repository Impact

| Repo | Files changed |
|---|---|
| `workflow/` (`agent-runtime/`) | `src/main.ts`, `src/bootstrap/bootstrap.ts`, `Dockerfile`, `DOCKER.md`, `QUICKSTART.md` |
| `workflow/` (`agent-runtime/`) | `orchestration/.env.example`, `orchestration/docker-compose.yml`, `orchestration/github-actions/scheduled.yml`, `orchestration/kubernetes/cronjob.yaml`, `orchestration/systemd/agent-runtime.service` |
| `workflow/` (`agent-runtime/`) | Add: `src/bootstrap/agent-context.ts`, `src/loop/run-claude.ts` |
| `workflow/` (`agent-runtime/`) | Delete: `src/loop/run-task.ts`, `src/claim/suggested-next-step.ts`, `src/logging/log-sink.ts` |
| `workspace/` (management repo) | `docs/features/agent-runtime-hardening/` only |

No changes to `workspace.yaml`, `agent.yaml` schema, task YAML schema, or any workflow skill.

## Dependency & Parallelization Analysis

```
Wave 1 — all independent, run in parallel
  T1: SSH_PRIVATE_KEY env var (main.ts + credential docs + all orchestration templates)
  T2: Bootstrap impl repo cloning (bootstrap.ts)
  T3: Dockerfile claude CLI install + GITHUB_TOKEN docs
  T4: Agent context generator (src/bootstrap/agent-context.ts) — pure new file, no deps

Wave 2 — depends on T3 (claude in image) and T4 (context generator available)
  T5: run-claude.ts + main.ts wiring (replaces run-task.ts, wires agent context + claude invocation)

Wave 3 — depends on T5 (all callers updated before deletion)
  T6: Delete run-task.ts and orphaned modules; update all imports; integration test pass
```

T1 and T2 are fully independent of each other and of T3/T4. T3 and T4 are independent of each other. T5 cannot start until T3 (claude available in image, GITHUB_TOKEN documented) and T4 (agent-context.ts exists to import). T6 must be last — deleting files before T5 is wired would break compilation.

## Open Questions Resolved

| Question | Decision |
|---|---|
| Agent CLAUDE.md injection | Written as `-p` prompt string; workspace `CLAUDE.md` read automatically from cwd |
| Token budget enforcement | `--max-turns` = `max_iterations` (loop guard) + post-exit token audit (budget guard) |
| Exit signal | Read task YAML state after `claude` exits; exit code only used for crash detection |
