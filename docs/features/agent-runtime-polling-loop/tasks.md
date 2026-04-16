# Tasks — Agent Runtime: Continuous Polling Loop

Feature status: `in_tdd` | Stage: `tasks` (draft)
Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Add `idle_sleep_seconds` to agent config schema and interface | — |
| T2 | 2 | Refactor `main.ts` to continuous polling loop | T1 |
| T3 | 1 | Replace K8s CronJob with Deployment; remove systemd orchestration | — |
| T4 | 3 | Update all documentation and support scripts | T2, T3 |
| T5 | 1 | Fix `init-workspace` Check 3 sync direction | — |
| T6 | 1 | Restructure log file path to per-task subdirectory | — |

---

## T1 — Add `idle_sleep_seconds` to agent config schema and interface

### Description
Add the new `idle_sleep_seconds` optional integer field to every layer of the agent config stack: JSON Schema, TypeScript interface, and the example config files. This is a pure additive change — no existing `agent.yaml` files break. T2 is blocked on this task because `main.ts` must be able to read `config.idle_sleep_seconds` from the validated config object.

### Required skills

### Model overrides

### Subtasks
- [ ] Add `idle_sleep_seconds` to `schemas/agent.schema.json` — optional integer ≥ 0, default 60 in description
- [ ] Add `idle_sleep_seconds?: number` to `AgentConfig` interface in `src/config/validate-agent-yaml.ts`
- [ ] Document `idle_sleep_seconds` in `orchestration/local/agent.yaml.example` with comment explaining default and single-shot note (`0` = exit after one cycle)
- [ ] Update the K8s ConfigMap agent.yaml block in `orchestration/kubernetes/cronjob.yaml` (before it is replaced by T3) to include the field — or defer to T3 since T3 replaces the file

---

## T2 — Refactor `main.ts` to continuous polling loop

### Description
The core behavioral change. Refactor `main()` so that bootstrap runs once at startup and the scan+claim+run logic runs in a `while(true)` loop with a configurable sleep between cycles. Add a per-cycle `pullWorkspaces()` step that `git fetch + reset --hard` on each watched workspace before scanning — this replaces the full bootstrap re-run that currently happens on each Docker restart. Classify git pull errors as fatal or retryable. When `idle_sleep_seconds` is 0, exit after one cycle (single-shot compatibility).

### Required skills
- typescript-best-practices

### Model overrides

### Subtasks
- [ ] Extract current scan+claim+run block from `main()` into `runOneCycle()` function
- [ ] Add `pullWorkspaces(watchUrls, sshKeyPath, workspacesRoot, emit)` function: `syncRepo()` on each watched URL, then reads each workspace's `workspace.yaml` and `syncRepo()` on every `repos[]` entry not already in the watches list (implementation repos) — verify where implementation repos are currently cloned/pulled before writing this to avoid conflicts with existing logic
- [ ] Export `syncRepo` from `src/bootstrap/bootstrap.ts` if not already exported
- [ ] Wrap `runOneCycle()` in `while(true)` loop; emit `activation_idle` and sleep `(config.idle_sleep_seconds ?? 60) * 1000` ms on idle cycle
- [ ] After a successful task run, also sleep the full `idle_sleep_seconds` before next cycle
- [ ] Add git pull error classification: emit `poll_git_halt` and skip the affected workspace this cycle (loop keeps running) on non-fast-forward/404/auth failure; emit `poll_git_warn` and continue on transient network errors — never exit the process on a pull failure
- [ ] When `idle_sleep_seconds === 0`: run one cycle and return 0 (single-shot mode — no loop)
- [ ] Update comment in `scripts/run-once.sh` to note the name is historical; the process now runs continuously unless `idle_sleep_seconds: 0`
- [ ] Add/update unit tests for: idle sleep, single-shot mode, git pull fatal classification, git pull retryable classification, post-task sleep

---

## T3 — Replace K8s CronJob with Deployment; remove systemd orchestration

### Description
The CronJob was appropriate when the container was single-shot. With an internal polling loop, a long-running Deployment is the correct K8s primitive. The systemd timer+service pattern is removed entirely — it was designed exclusively for external one-shot scheduling and has no role in the continuous-loop model. This task replaces/removes orchestration manifests without touching any TypeScript.

### Required skills

### Model overrides

### Subtasks
- [ ] Create `orchestration/kubernetes/deployment.yaml` containing: Namespace (retained), PVC (retained), ConfigMap with updated `agent.yaml` including `idle_sleep_seconds: 60`, Secret (retained), Deployment (replaces CronJob)
- [ ] Deployment spec: `restartPolicy: Always` (default), liveness probe (exec check that node process is running), retain resource limits and security context from CronJob
- [ ] Remove `orchestration/kubernetes/cronjob.yaml`
- [ ] Remove `orchestration/systemd/` directory entirely (both `agent-runtime.service` and `agent-runtime.timer`)

---

## T4 — Update all documentation and support scripts

### Description
Every user-facing doc and setup script describes the old single-shot / Docker-restart model. This task updates them all to reflect the new continuous-loop lifecycle. All changes are documentation-only — no logic changes.

### Required skills

### Model overrides

### Subtasks
- [ ] `QUICKSTART.md`: remove "Each container is a single activation cycle — Docker Compose restarts it automatically after each exit" and similar language; describe the internal polling loop; document `idle_sleep_seconds`; update "Other deployment targets" table to reference `deployment.yaml` not `cronjob.yaml`
- [ ] `DOCKER.md`: add `idle_sleep_seconds` to the env var / config reference table; update lifecycle description
- [ ] `orchestration/local/docker-compose.yml`: update top comment ("Each loops continuously" is already technically right, but should clarify the loop is now internal and `restart: unless-stopped` is for crash recovery only)
- [ ] `scripts/bootstrap-agent-host.sh`: update macOS "next steps" section which references one-shot `docker run` and "docker compose --profile prod"; update systemd install section to reflect the timer removal and service type change
- [ ] Review `docs/OPERATOR-GUIDE.md` and `docs/TROUBLESHOOTING.md` for references to CronJob, timer, single-shot, or `restart: unless-stopped` as the loop driver — update each reference found
- [ ] Verify `scripts/` directory for any other scripts that assume single-shot semantics; remove or update them

---

## T6 — Restructure log file path to per-task subdirectory

### Description
The current log path is `docs/features/<featureId>/logs/<taskId>_<safeIso>.jsonl` — a flat directory where all task runs are mixed together. The new path is `docs/features/<featureId>/logs/<taskId>/<safeIso>.jsonl` — each task gets its own subdirectory, making it easy to browse or tail logs for a specific task across multiple runs. Each task run still creates its own file (one file per `runClaude()` invocation, stamped with the run start ISO timestamp). This is a path-only change; log content and format are unchanged.

### Required skills
- typescript-best-practices

### Model overrides

### Subtasks
- [ ] Update `LOGS_DIR` structure in `src/paths.ts`: change `featureLogsDirPath` to return `docs/features/<featureId>/logs/<taskId>/` and update `logFileRelPath` accordingly
- [ ] Update `deriveLogPath` in `src/logging/log-sink.ts`: new pattern is `<workspaceRoot>/docs/features/<featureId>/logs/<taskId>/<safeIso>.jsonl` (taskId becomes a directory, not a filename prefix)
- [ ] Update path layout comment at the top of `src/paths.ts` to reflect the new structure
- [ ] Confirm `mkdirSync` in the log sink uses `recursive: true` so the new nested directory is created automatically
- [ ] Update any tests that assert on the old log file path pattern

---

## T5 — Fix `init-workspace` Check 3 sync direction

### Description
Check 3 in `workflow_skills/init-workspace/SKILL.md` currently instructs the agent to read keys from `.env` and write missing ones into `.env.template`. This is backwards: `.env` contains real secrets and is never the source of truth for the template. The correct behaviour is to warn when `.env` is missing keys that exist in `.env.template` — never write from `.env` into `.env.template` automatically.

### Required skills

### Model overrides

### Subtasks
- [ ] Update Check 3 in `workflow_skills/init-workspace/SKILL.md`: replace the auto-sync rule with a warning-only rule
- [ ] New Check 3 rule: compare `.env.template` against `.env`; for any key in `.env.template` that is missing from `.env`, warn the operator and prompt them to add it — do not modify `.env.template`
- [ ] Remove any language that suggests writing from `.env` → `.env.template`
- [ ] Update the Check 3 summary line in the health-check output table to reflect the corrected direction
