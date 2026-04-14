# Handoff — distributed-agent-team

**Feature:** Distributed agent team (self-activating agents pulling work from workspace)
**Completed:** 2026-04-14
**All tasks:** T1–T11 done (11/11)

---

## What was built

A fully self-activating agent runtime that allows one or more Claude agents to run on independent hosts, pull ready tasks from a workspace, execute them, and push results — with no human coordination between runs.

### Core components (all in `agent-runtime/`)

| Component | Location | What it does |
|---|---|---|
| Agent YAML schema + validator | `src/validate-agent-yaml.ts` | Validates `agent.yaml` config at boot |
| Git-commit log sink | `src/logging/` | Streams structured events to JSONL on a git branch |
| Eligibility matcher | `src/match.ts` | Zero-token pre-filter: status=ready, deps done, skill present |
| Claim protocol | `src/claim/claim-task.ts` | Git commit-SHA contention — exactly one agent wins per task |
| Tool-use loop | `src/loop/run-task.ts` | Anthropic SDK loop with budget, iteration cap, skill loading, model policy |
| Bootstrap | `src/bootstrap.ts` | Container-start workspace + workflow sync with fail-fast validation |
| Docker image | `Dockerfile` | Multi-stage: Node.js runtime + Python + Go; one activation per container |
| Orchestration templates | `orchestration/` | k8s CronJob, unified docker-compose (dev + prod profiles), systemd timer, GitHub Actions |
| Bootstrap script | `scripts/bootstrap-agent-host.sh` | One-command host setup with Docker detection, credential collection, dry run |
| Operator docs | `docs/OPERATOR-GUIDE.md` | All deployment targets, env vars, model policy, blocked task handling, escalation |
| Troubleshooting guide | `docs/TROUBLESHOOTING.md` | All 6 `blocked_reason` values plus SSH, stale claims, git sync, image pull |
| Integration tests | `tests/integration/` | 157 tests total; 5 new integration tests covering full activation pipeline |

### Workflow rule changes

All propagated to `CLAUDE.shared.md` → `CLAUDE.md` via `sync-workspace-rules`:

- **Per-task required skills** — skills declared in `tasks.md → ### Required skills`, not on `agent.yaml`. Agents are uniform full-stack.
- **Model policy** — `workspace.yaml → model_policy` defines `allowed` + `default` per phase (`implementation`, `self_review`, `pr_description`, `suggested_next_step`). Per-task overrides via `### Model overrides` in `tasks.md`.
- **Narrative / state split** — task YAMLs hold only machine-mutable state; `tasks.md` holds description, subtasks, skills, model overrides.
- **Status transition rules** — explicit transition table enforced; `todo → in_progress` never valid.
- **Timestamp rule** — all log `at:` fields must use real UTC via `date -u +%Y-%m-%dT%H:%M:%SZ`.
- **Branch merge rule** — when marking a task `done`, a PR on the management repo merging the feature branch into `main` is required.
- **start-implementation hardened** — `git fetch` + `reset --hard origin/<base>` before branch creation; git failures logged as `blocked` in task YAML.

### Workflow diagrams added

- `docs/task-workflow.png` — task status transition diagram (referenced in `CLAUDE.shared.md`)
- `docs/feature-workflow.png` — feature lifecycle diagram (referenced in `CLAUDE.shared.md`)

---

## How to run an agent

**Quick start (local dev, two agents):**

```bash
cd agent-runtime/orchestration
cp .env.example .env          # fill in ANTHROPIC_API_KEY, GIT_AUTHOR_EMAIL, SSH_KEY_PATH, WORKSPACE_SSH_URL
cp agent.yaml.example agent.yaml
docker compose --profile dev up
```

**Production (supervisor loop):**

```bash
docker compose --profile prod up -d
```

**New host setup:**

```bash
bash agent-runtime/scripts/bootstrap-agent-host.sh
```

---

## Operational notes

- **Kill switch:** set `enabled: false` in `agent.yaml` — all containers exit cleanly after the current activation.
- **Blocked tasks** — check `blocked_reason` in the task YAML. See `docs/OPERATOR-GUIDE.md §8` for per-reason resolution steps.
- **Model escalation** — agent sets `blocked_reason: model_escalation_requested`; add `### Model overrides` to the task in `tasks.md` and reset to `ready`.
- **Stale claims** (`in_progress` with no agent running) — reset `status: ready`, `blocked_reason: null` and push to main.
- **Logs** — structured JSON to stdout; if `log_sink.enabled: true`, JSONL also committed to the feature branch under `docs/features/<id>/logs/`.

---

## Known gaps / future work

- No GHCR image published yet — operators must build locally: `docker buildx build -f agent-runtime/Dockerfile -t agent-runtime:local <repo-root>`.
- No GitHub Actions CI workflow for the agent-runtime test suite.
- k8s CronJob template does not yet include a Horizontal Pod Autoscaler example.
