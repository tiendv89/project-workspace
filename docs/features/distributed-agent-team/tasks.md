# Tasks — distributed-agent-team

> Feature status: `in_tdd` — technical design updated 2026-04-14: per-phase model allowlist with workspace defaults + task-level overrides replaces per-task Opus approval fields. `agent.yaml` drops `models` section. Old T11 (Opus wiring) folded into T6/T11(docs). 11 tasks total.
> Task stage: **draft** — awaiting human approval.
>
> Narrative (description + required skills + subtasks) lives in this file. Machine-readable state (status, deps, branch, log, PR) lives per-task in `tasks/T<n>.yaml`. Agents mutate only the YAML files; this document stays stable unless scope changes.
>
> Runtime language for the agent: **TypeScript + Node.js** (decided at task breakdown; see technical-design.md §Q2 detail).

---

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Update workflow rules for per-task skills + full-stack agents + model policy grammar (W1–W9, W12–W13) | — |
| T2 | 1 | Define `agent.yaml` schema and TypeScript validator | — |
| T4 | 1 | Implement git-commit log sink library (TypeScript) | — |
| T3 | 2 | Extend task + workspace schemas (model_policy, escalation, drop role) (W6, W10) | T1 |
| T5 | 3 | Implement zero-token eligibility matcher | T1, T2, T3 |
| T6 | 3 | Integrate Anthropic Agent SDK tool-use loop with budget enforcement, dynamic skill loading, and model policy resolution | T2, T3 |
| T7 | 3 | Implement git-based claim protocol with commit-SHA contention | T3 |
| T8 | 3 | Container-start workspace pull with fail-fast validation + `skill_reference_audit` event | T1, T2 |
| T9 | 4 | Build agent-runtime Docker image and contract | T4, T5, T6, T7, T8 |
| T10 | 5 | Produce orchestration templates (k8s CronJob + alternatives) | T9 |
| T11 | 6 | End-to-end bootstrap scripts, integration tests, and operator docs | T9, T10 |

(Wave numbers reflect the earliest wave each task can start — they're not mutually exclusive slots.)

---

## T1 — Update workflow rules for per-task skills + full-stack agents + model policy grammar (W1–W9, W12–W13)

### Description
Bring the shared workflow rules and skills into line with the re-approved technical design. This is a pure workflow-repo edit pass: no code, no runtime. It removes the agent-side role/skills concept, formalises the `### Required skills` grammar inside `tasks.md`, and drops dead configuration (`role_skill_overrides`, `workspace.yaml.roles:`).

This task is a hard prerequisite for T3, T5, and T8 because their contracts reference rules that don't exist yet in the current workflow.

### Required skills

(empty — pure markdown / YAML edits, no language-specific skill applies)

### Subtasks
- [ ] **W1** — `workflow/CLAUDE.shared.md`: remove the "Role skill overrides" section entirely. Replace with a short "Per-task required skills" note pointing readers to `tasks.md`'s `### Required skills` subsection as the source of capability.
- [ ] **W2** — `workflow/CLAUDE.shared.md`: add a top-level rule clarifying that task YAML files contain only machine-mutable state (status, deps, branch, log, pr, execution). Logical intent — description, subtasks, required skills — lives in `tasks.md`.
- [ ] **W3** — `workflow/workflow_skills/tech-lead/SKILL.md`: add rule: every `## T<n>` in a generated `tasks.md` MUST include a `### Required skills` subsection (empty list permitted). Skill slugs must match directory names under `workflow/technical_skills/`. Document the slug regex `^[a-z0-9][a-z0-9-]*$` and the parser's rules (bounded by the next `###` / `## ` / EOF).
- [ ] **W4** — `workflow/workflow_skills/tech-lead/SKILL.md`: remove references to `role` from the "Required task fields" list. Update the lean-YAML example to drop `role`. Update the FARO-197 parallelization-diagram template — agents are uniform, so `(role)` annotations no longer drive matching; annotate tasks with a short descriptor (e.g. skill focus) or leave bare, tech-lead's choice.
- [ ] **W5** — `workflow/schemas/task.yaml.example`: remove the `role:` field. Keep the explanatory header.
- [ ] **W7** — `workflow/workflow_skills/init-workspace/SKILL.md` + templates: stop emitting `role_skill_overrides` and `workspace.yaml.roles:` list. Update `workspace.yaml` template accordingly.
- [ ] **W8** — `workflow/workflow_skills/init-feature/SKILL.md` + templates: drop `role:` from the generated task YAML template. Add an empty `### Required skills` stub to the generated `tasks.md` task template.
- [ ] **W9** — `workflow/workflow_skills/start-implementation/SKILL.md`: verify no role-based validation exists; remove any that surfaces. Remove any `--model-override` flag or `model_override` field handling — model selection is now driven by `workspace.yaml` `model_policy` + `tasks.md` `### Model overrides`, not by start-implementation flags.
- [ ] **W12** — `workflow/workflow_skills/tech-lead/SKILL.md`: add rule for optional `### Model overrides` subsection per task in `tasks.md`. Document the grammar: phase name, `allowed` list, `default` value. Phases must be one of `implementation`, `self_review`, `pr_description`, `suggested_next_step`. If absent, workspace defaults apply.
- [ ] **W13** — `workflow/templates/workspace/workspace.yaml`: add `model_policy` section with per-phase `allowed` + `default` structure. Document that this is the centralized model cost-control surface.
- [ ] Acceptance: `/tech-lead` on a fresh feature emits `tasks.md` with `### Required skills` stubs (and optionally `### Model overrides`) and task YAMLs without `role:`; `/init-workspace` produces `workspace.yaml` without `role_skill_overrides` or top-level `roles:` but with `model_policy`; a dry run of `/start-implementation` against a task with no `role` field succeeds.

---

## T2 — Define `agent.yaml` schema and TypeScript validator

### Description
Canonical `agent.yaml` shape for every agent instance. Minimal: no `role`, no `skills[]`, no `agent_id`, no `models` (model selection is driven by `workspace.yaml` `model_policy` + task-level `### Model overrides`, not by agent config). Just `watches` + `enabled` + `jitter_max_seconds` + `budget` + `log_sink`. Ships with a TypeScript validator that both the runtime and CI can import.

Foundational because T5 (eligibility matcher), T6 (SDK loop), and T8 (bootstrap) all read validated `agent.yaml` at start.

### Required skills
- typescript-best-practices

### Subtasks
- [x] Create `workflow/schemas/agent.yaml.example` with the shape from technical-design.md §Data & config schemas — `watches`, `enabled`, `jitter_max_seconds`, `budget.{max_tokens_per_task, max_iterations, suggested_next_step_max_tokens}`, `log_sink.enabled`. Every field must have an inline YAML comment explaining its purpose, valid values, and default behavior (e.g. `# Maximum tokens the agent may consume per task. Positive integer.`). Include a header comment stating: no agent-side role/skills/models, attribution via `GIT_AUTHOR_EMAIL`, model selection via workspace.yaml model_policy.
- [x] Create `workflow/schemas/agent.schema.json` — JSON Schema (draft-07 or 2020-12) that precisely constrains the example file. Reject unknown properties. Constrain budget integers to positive ranges.
- [x] Implement `workflow/agent-runtime/src/config/validate-agent-yaml.ts` — parses YAML, runs Ajv against `agent.schema.json`, maps validation errors to human-readable messages that point at the offending field path.
- [x] Export a typed `AgentConfig` from `validate-agent-yaml.ts`. Downstream TypeScript code (T5/T6/T8) imports the type; no duplicate shape declarations.
- [x] Unit tests covering: valid example passes; missing required field fails with a clear message; unknown field fails; bad types fail.
- [x] Document the schema in `workflow/agent-runtime/README.md` — one full example, one minimal example, plus a short note explaining why there's no `skills[]` or `models` here (points to `tasks.md` and `workspace.yaml` as the sources).
- [x] Acceptance: `validate-agent-yaml` rejects every intentionally-broken fixture and accepts every intentionally-valid fixture; running it on the example file in CI passes.

---

## T3 — Extend task + workspace schemas (model_policy, escalation, drop role) (W6, W10)

### Description
Adds per-phase model policy to `workspace.yaml` schema, escalation `blocked_reason` values to the task schema, and a `### Model overrides` parser for `tasks.md`. Also executes W6 (drop `role` from existing task YAMLs in this feature) and W10 (keep other workspaces untouched — additive change).

Depends on T1 because W5 removed `role` from `workflow/schemas/task.yaml.example` and W10–W11 froze the `### Model overrides` grammar.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add `model_policy` to `workflow/schemas/workspace.schema.json` (or create if it doesn't exist): per-phase `allowed` (array of model ID strings) + `default` (string, must be in `allowed`). Phases: `implementation`, `self_review`, `pr_description`, `suggested_next_step`. Reject unknown phases. Export a typed `ModelPolicy` from TypeScript.
- [ ] Create `workflow/schemas/workspace.yaml.example` additions showing the `model_policy` section with inline comments explaining each phase and the centralized cost-control purpose.
- [ ] Update `workflow/schemas/task.yaml.example` to document the enumerated `blocked_reason` values (`budget_exceeded`, `iteration_cap_exceeded`, `no_progress`, `model_escalation_requested`, `skill_missing`, `runtime_error`). No `model_override*` fields — model selection lives in `workspace.yaml` + `tasks.md`.
- [ ] Add TypeScript types for the task schema under `workflow/agent-runtime/src/types/task.ts`. Re-used by T5/T6/T7.
- [ ] Implement `workflow/agent-runtime/src/config/parse-model-overrides.ts` — parses a task's `### Model overrides` subsection from `tasks.md`. Returns `{ [phase]: { allowed: string[], default: string } }` for declared phases, empty object if absent. Emits `model_override_parse_warning` on malformed input and returns empty (workspace defaults apply).
- [ ] Implement `workflow/agent-runtime/src/config/resolve-model-policy.ts` — merges workspace `model_policy` + task-level overrides. Returns the effective `{ allowed, default }` for a given phase. Validates that `default` is in `allowed`; if not, falls back to cheapest in `allowed` and emits `model_fallback` event.
- [ ] Strip `role:` from every `docs/features/distributed-agent-team/tasks/T<n>.yaml` in this workspace (W6 + W10). Append a `schema_updated` log entry to each.
- [ ] Add an Ajv schema `workflow/schemas/task.schema.json` covering the task YAML shape (status enum, depends_on array, execution sub-object, pr sub-object, log array). Reject unknown top-level properties except commonly-used optional ones.
- [ ] Unit tests: workspace model_policy validation (valid passes, unknown phase fails, missing default fails); model-overrides parser (valid, empty, malformed sections); merge logic (task override replaces workspace for declared phase, inherits for undeclared); task schema fixtures (missing status, bad enum, valid escalation blocked_reason).
- [ ] Acceptance: all 11 YAMLs in this feature validate; `resolve-model-policy` correctly merges workspace defaults with task overrides; a task with `### Model overrides` adding Opus resolves to Opus as default for that phase.

---

## T4 — Implement git-commit log sink library (TypeScript)

### Description
Per-run, task-scoped JSONL event log. One file per run at `<workspace_root>/docs/features/<feature_id>/logs/T<n>_<ISO-start>.jsonl` on the task's feature branch. Pure append semantics: the library opens, `fs.appendFile`-s a line, and flushes. No read-modify-write, so two different tasks never contend.

Independent of everything else — can be built and tested in isolation, then linked into the runtime (T6/T8) later.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `workflow/agent-runtime/src/logging/log-sink.ts` exporting an `openLogSink({ workspaceRoot, featureId, taskId, runStartIso })` factory that returns an object with `emit(event)` and `close()` methods.
- [ ] Filename convention: `T<n>_<ISO-start>.jsonl` where ISO-start has `:` replaced by `-` (filesystem-safe). Library creates the `logs/` directory if missing.
- [ ] Event schema (TypeScript type): `{ at: string (ISO), by: string (GIT_AUTHOR_EMAIL), type: string, iteration?: number, tokens?: { in, out, total }, duration_ms?: number, details?: Record<string, unknown> }`. Reject events with unknown top-level fields at runtime for forward-compat safety.
- [ ] First line of every file: `type: "run_started"` event containing the agent's resolved git identity, commit SHA of the workflow repo, and the agent.yaml version. Written synchronously on `openLogSink`.
- [ ] Last line on graceful shutdown: `type: "run_ended"` event with `reason: done | blocked | error`. Emitted by `close()`.
- [ ] Commit + push each appended batch. A batch is "every event emitted in a single activation cycle"; the library buffers and flushes on `close()` (not per-event) to keep commit volume bounded.
- [ ] Unit tests: file path derivation; run_started ordering; append correctness under simulated concurrent writers (should not happen in practice per design, but prove independence); graceful and ungraceful close paths.
- [ ] Acceptance: a test that starts two concurrent "runs" of different tasks produces two separate JSONL files with no cross-write; a run that crashes mid-loop leaves a valid partial JSONL (each line is an intact JSON object).

---

## T5 — Implement zero-token eligibility matcher

### Description
Pure-code (no LLM) filter that picks the next eligible task for this agent to attempt. Under the new design, eligibility is:

1. `tasks/T<n>.yaml.status == ready`.
2. All task IDs in `depends_on` are `done`.
3. `repo` value is one of the repos reachable from `agent.watches`.
4. Every slug in the task's `tasks.md` `### Required skills` subsection corresponds to an existing directory under the pulled `workflow/technical_skills/`.

No role filter. No agent-side skills intersection. Missing-skill tasks are skipped with a stdout `task_skipped_missing_skill` event (never claimed).

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `workflow/agent-runtime/src/eligibility/match.ts` exposing `findEligibleTasks(agentConfig, workspaceRoot, workflowRoot): Task[]`.
- [ ] Implement `workflow/agent-runtime/src/eligibility/parse-tasks-md.ts` — parses `tasks.md` into `{ taskId → { requiredSkills: string[] } }`. Regex-based per the grammar in technical-design.md §Q6 detail: locate `## T(\d+)\s+—`, scoped by next `## ` or EOF; within that block, locate `### Required skills`, scoped by next `### ` / `## ` / EOF; collect consecutive `- <slug>` lines; validate slug pattern `^[a-z0-9][a-z0-9-]*$`.
- [ ] Malformed required-skills subsection → emit `tasksmd_parse_warning` event to stdout, skip that task. Never produce a false match.
- [ ] Dependency resolution: load all `tasks/T*.yaml` for the feature, build the `done`-set, filter by `depends_on ⊆ done`.
- [ ] Skill-availability check: for each candidate's required skills, check that `workflow/technical_skills/<slug>/SKILL.md` exists. Missing → emit `task_skipped_missing_skill` event, drop the candidate.
- [ ] Watches match: expand `agent.watches` (workspace repos) into the set of repo IDs that agent is allowed to touch. Drop candidates whose `task.repo` isn't in that set.
- [ ] Deterministic ordering: after filtering, return candidates sorted by task ID ascending (stable).
- [ ] Unit tests: tasks.md fixtures covering valid, empty, and malformed required-skills sections; YAML fixtures covering ready/todo/in_progress/blocked/done; unmet-dependency cases; missing-skill cases; repo-mismatch cases.
- [ ] Performance: a workspace with 100 features × 20 tasks each must return within 500ms (no LLM calls — this is filesystem + regex).
- [ ] Acceptance: matcher returns a correct eligible set across all fixture cases; zero token usage (no Anthropic client instantiated).

---

## T6 — Integrate Anthropic Agent SDK tool-use loop with budget enforcement, dynamic skill loading, and model policy resolution

### Description
The heart of the runtime. Runs one claimed task end-to-end inside a tool-use loop, enforcing three hard limits between iterations (token budget, iteration cap, no-progress detection). Dynamically loads the task's required skills into the system prompt at start. Model selection per phase is driven by `workspace.yaml` `model_policy` merged with the task's optional `### Model overrides` from `tasks.md` — the agent uses the merged default and falls back to the cheapest allowed model if the default is unavailable.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add `@anthropic-ai/sdk` (and the Agent SDK package, if split) as a dependency in `workflow/agent-runtime/`. Wire `ANTHROPIC_API_KEY` from the agent host's `.env` (one key per agent).
- [ ] Implement `workflow/agent-runtime/src/loop/run-task.ts`: loads `task.yaml`; reads the task's `### Required skills` from `tasks.md`; concatenates each skill's `SKILL.md` body into a dedicated system-prompt block; resolves model per phase using T3's `resolve-model-policy` (workspace defaults merged with task's `### Model overrides`); runs the tool-use loop.
- [ ] Model selection per phase: implementation → merged default for `implementation`; self-review → same model as implementation; PR description → merged default for `pr_description`; suggested_next_step → merged default for `suggested_next_step`. If the selected model is unavailable (API error), fall back to cheapest in the phase's `allowed` list.
- [ ] Tool surface: `bash`, `read_file`, `write_file`, `edit_file`, `git` subset (add/commit/push). Mirror Claude Code's toolset sufficiently to run the execution contract.
- [ ] Budget enforcement between iterations: `per_task_tokens` exceeded → abort with `blocked_reason: budget_exceeded`. `max_iterations` reached → abort with `blocked_reason: iteration_cap_exceeded`. Same tool args repeated 3 iterations in a row → abort with `blocked_reason: no_progress`.
- [ ] Escalation path: when the SDK loop self-detects insufficient capability (heuristic — e.g. hits iteration cap or identical-failure pattern), write `blocked_reason: model_escalation_requested` + `blocked_details` (including `current_model`) to `task.yaml`, commit, exit cleanly. No further API calls. Human resolves by editing `### Model overrides` in `tasks.md` and resetting task to ready.
- [ ] Runtime-error path: any uncaught exception is caught at the top of `run-task.ts`, converted to `blocked_reason: runtime_error` with a truncated stack trace in `blocked_details`, committed, then process exits non-zero. Never leave the task stuck in `in_progress` (Constraint #11).
- [ ] Token/iteration telemetry: emit a `task_work_iteration` event to the log sink after every iteration (input tokens, output tokens, model used, cache-hit metrics, duration_ms).
- [ ] Unit tests: mocked SDK that returns scripted tool calls — verify budget + iteration caps trigger at the right thresholds; model policy resolution uses workspace defaults when no task override exists; task-level Model overrides are respected; fallback to cheapest when default unavailable; runtime-error path lands tasks in `blocked` not `in_progress`.
- [ ] Acceptance: a sample task runs end-to-end under budget using workspace default model; a task with `### Model overrides` adding Opus runs with Opus; an intentionally over-budget task aborts with correct `blocked_reason`; escalation path writes `model_escalation_requested` with `current_model` in details.

---

## T7 — Implement git-based claim protocol with commit-SHA contention

### Description
Atomic claim of a `ready` task via a single git commit + push. Contention is detected by git push rejection; resolution is by commit SHA (not identity), so the protocol is correct even when multiple agent hosts share a single `GIT_AUTHOR_EMAIL`.

Short pre-commit jitter de-synchronises agents that pull from the same cron tick.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `workflow/agent-runtime/src/claim/claim-task.ts` exporting `claimTask({ workspacePath, taskId })`. Identity is sourced from the resolved git env (GIT_AUTHOR_EMAIL), not a parameter.
- [ ] Mutation: set `status: in_progress`, `execution.last_updated_by: <GIT_AUTHOR_EMAIL>`, `execution.last_updated_at: <ts>`. Commit on the base branch for the task's repo. Push.
- [ ] Pre-commit jitter: sleep random 50–500ms (bounded by `agent.jitter_max_seconds * 1000`) before the commit. De-synchronises concurrent claim attempts.
- [ ] Push rejection handling: on non-fast-forward reject, fetch latest. Compare current remote HEAD SHA to the SHA the library remembered from its own push. **If they match → this agent won** (a concurrent rebase re-ordered the push); claim stands. **If they differ → someone else won**; abandon and return `{ won: false }`. Do NOT rely on `execution.last_updated_by` or any identity string — this keeps the protocol correct when agents share a git identity.
- [ ] Post-claim check: after declaring victory, re-read the task YAML and confirm `status: in_progress` and `last_updated_by` matches this agent's GIT_AUTHOR_EMAIL. If not (rare race), roll back.
- [ ] Suggested-next-step on blocked: when the runtime exits a task with any `blocked_reason`, record a `suggested_next_step` string (generated from task context using the Haiku tier) in `task.yaml.execution.suggested_next_step` for human triage.
- [ ] Unit + integration tests: 5-agent concurrent-claim simulation on 10 ready tasks → exactly one winner per task, no orphans, no double-claims. Include a sub-case where all 5 agents share the same `GIT_AUTHOR_EMAIL` to prove the SHA-based self/other check stands in for identity.
- [ ] Acceptance: contention test passes; losers re-run eligibility and pick the next match.

---

## T8 — Container-start workspace pull with fail-fast validation + `skill_reference_audit` event

### Description
Every container start performs three things: pull each watched workspace fresh, validate `agent.yaml`, and audit skill references across all `tasks.md` files. Fail-fast on dirty git state or invalid config. The skill audit is informational (non-fatal stdout warnings) so operators see stale skill references up-front.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `workflow/agent-runtime/src/bootstrap/bootstrap.ts` that runs once per container start: (1) clone or pull each workspace in `agent.watches[]` using the agent's SSH key; (2) clone or pull the workflow repo to a known path; (3) load and validate `agent.yaml` via T2's validator; (4) fail-fast on merge conflict or dirty state.
- [ ] Clone-vs-pull logic: empty target path → `git clone`; present → `git fetch` + `git reset --hard origin/<base_branch>`. No silent merge commits.
- [ ] Skill reference audit: after pulls succeed, enumerate `### Required skills` slugs across all `tasks.md` files in every watched workspace (reuse T5's parser). For any slug that isn't a directory under `workflow/technical_skills/`, emit a `skill_reference_audit` event to stdout listing the (workspace_id, feature_id, task_id, missing_slug) tuple. Continue bootstrap — this warning is informational, not fatal.
- [ ] Exit codes: `0` = success, `2` = agent.yaml validation failed, `3` = git clone/pull failed, `4` = unexpected bootstrap error.
- [ ] Emit bootstrap events to stdout (non-task logs go to stdout per Q7 detail): `bootstrap_started`, `workspace_cloned`, `workspace_pulled`, `bootstrap_failed` (with reason), `skill_reference_audit`, `bootstrap_ready`.
- [ ] Unit + integration tests: a fresh container clones cleanly; a pre-populated-but-dirty workspace is reset to match origin; a broken `agent.yaml` fails with exit code `2` and an actionable log event; a `tasks.md` with a typo'd skill slug produces a `skill_reference_audit` event and bootstrap still succeeds.
- [ ] Acceptance: fresh container bootstraps in under 30s on a small workspace; intentionally broken `agent.yaml` fails fast with exit code `2`.

---

## T9 — Build agent-runtime Docker image and contract

### Description
Package the T4–T8 runtime plus T6's SDK loop into a single reproducible Docker image. The image's env-in/behavior-out contract is the stable interface that T10's orchestration templates target.

### Required skills

(empty — Dockerfile + shell scripting; no TypeScript/Python skill applies to image packaging)

### Subtasks
- [ ] Write `workflow/agent-runtime/Dockerfile`: minimal Node base (node:20-alpine or distroless + tini), install `git` + `openssh-client`, `COPY` the built runtime (`dist/` from `tsc` output) + `scripts/`. ENTRYPOINT = `/app/scripts/run-once.sh` which sequences bootstrap → eligibility → claim → run-task → flush-logs → exit.
- [ ] Multi-stage build: stage 1 runs `npm ci && npm run build`; stage 2 copies only `dist/` + `node_modules` (production prune) into the runtime image. Image size target: < 300MB.
- [ ] Env contract documented in `workflow/agent-runtime/DOCKER.md`: required env vars (`ANTHROPIC_API_KEY`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `SSH_KEY_PATH`, `WORKSPACE_ROOT`), volume mounts (`/agent/data` for workspaces, `/agent/ssh` for key), exit code meaning, log destinations.
- [ ] Single run semantics: container does one activation cycle and exits. No long-running supervisor inside the container (Constraint-compatible with Q5 — orchestration is external).
- [ ] Kill switch honoured: if `agent.yaml.enabled: false`, bootstrap exits 0 within ~1s.
- [ ] Publish target: GHCR (tag TBD). CI workflow builds and pushes on merges to main.
- [ ] Acceptance: `docker run` with a minimal env + a single watched workspace containing one eligible task runs it to completion and exits 0; disabling via `agent.yaml.enabled: false` exits 0 within 2s.

---

## T10 — Produce orchestration templates (k8s CronJob + alternatives)

### Description
Operator-ready templates for running the T9 image on real infrastructure. k8s CronJob is the primary target; docker-compose, systemd, and GitHub Actions Scheduled Workflow are alternatives for smaller environments.

### Required skills

(empty — k8s manifests + shell + CI YAML; no runtime-language skill applies)

### Subtasks
- [ ] `workflow/agent-runtime/orchestration/kubernetes/cronjob.yaml` — k8s CronJob with `schedule: "*/5 * * * *"`, `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 1`, proper `SecurityContext`, ConfigMap for `agent.yaml`, Secret mounts for API key + SSH key.
- [ ] `workflow/agent-runtime/orchestration/docker-compose.yml` — a supervisor sidecar example for local dev: a busybox container running `while true; do docker run <agent-image>; sleep 300; done`. Documented for local iteration only (not production).
- [ ] `workflow/agent-runtime/orchestration/systemd/` — `agent-runtime.service` + `agent-runtime.timer` for bare-metal operators. Timer fires every 5min, service runs `docker run ...`.
- [ ] `workflow/agent-runtime/orchestration/github-actions/scheduled.yml` — a scheduled workflow that runs the image on a GHA runner. Useful for very small deployments.
- [ ] For each template, document the concrete `agent.yaml` wiring (where the file lives, how it's mounted, how secrets flow).
- [ ] Acceptance: k8s template applies cleanly against a kind cluster and produces successful Job runs; docker-compose template runs locally against a test workspace and produces a PR.

---

## T11 — End-to-end bootstrap scripts, integration tests, and operator docs

### Description
Final integration layer: the scripts and docs an operator actually uses to stand up an agent fleet, plus an end-to-end test harness that exercises T9's image against a real workspace. Includes documentation of the model policy system and escalation triage flow (previously a separate T11 task for Opus wiring — now folded in because model approval is implicit via `### Model overrides` in `tasks.md`).

### Required skills
- typescript-best-practices

### Subtasks
- [ ] `workflow/agent-runtime/scripts/bootstrap-agent-host.sh` — a single-command host setup: installs docker, pulls the image, writes a starter `agent.yaml`, provisions SSH key and API key, dry-runs.
- [ ] `workflow/agent-runtime/docs/OPERATOR-GUIDE.md` — covers: k8s deployment, docker-compose deployment, env vars, kill switch, log locations (stdout + `docs/.../logs/*.jsonl`), handling `blocked_reason` states, model policy configuration (`workspace.yaml` `model_policy` + per-task `### Model overrides`), escalation triage flow (agent blocks with `model_escalation_requested` → human edits `### Model overrides` in `tasks.md` → resets task to ready).
- [ ] `workflow/agent-runtime/docs/TROUBLESHOOTING.md` — common failure modes and their diagnostic steps (stale claim, missing skill, budget exhaustion, `model_escalation_requested`, model fallback events, SSH key misconfiguration, GIT_AUTHOR_EMAIL conflicts).
- [ ] `workflow/agent-runtime/tests/integration/` — TypeScript integration suite that stands up a local git bare-repo workspace, seeds a feature with 3 ready tasks (one success, one intentional budget blow-out, one missing-skill), runs the T9 image against it, asserts: 1 PR created, 1 task `blocked_reason: budget_exceeded`, 1 task skipped with `task_skipped_missing_skill`, no orphans.
- [ ] Acceptance: running the integration suite from scratch on a clean dev machine (docker + node + git) passes; bootstrap script produces a runnable host in under 5 minutes.
