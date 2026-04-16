# Handoff — Agent Runtime: Continuous Polling Loop

**Feature:** `agent-runtime-polling-loop`
**Date:** 2026-04-16
**Author:** matthew@swellnetwork.io

---

## What was built

The agent runtime was refactored from a single-shot process (restarted by external orchestrators after each exit) to a **continuous internal polling loop**. The container now stays alive indefinitely; git pulls, task scanning, claiming, and sleeping all happen inside the process.

### Core changes (all in `tiendv89/agent-workflow`)

| Task | Title | PR | Status |
|---|---|---|---|
| T1 | Schema + AgentConfig: add `idle_sleep_seconds` | [#28](https://github.com/tiendv89/agent-workflow/pull/28) | merged |
| T2 | Continuous polling loop refactor in `main.ts` | [#29](https://github.com/tiendv89/agent-workflow/pull/29) | merged |
| T3 | K8s Deployment manifest + systemd removal | [#30](https://github.com/tiendv89/agent-workflow/pull/30) | merged |
| T4 | Update all documentation and support scripts | [#31](https://github.com/tiendv89/agent-workflow/pull/31) | merged |
| T5 | Fix `init-workspace` Check 3 sync direction | [#27](https://github.com/tiendv89/agent-workflow/pull/27) | merged |
| T6 | Restructure log path to per-task subdirectory | [#32](https://github.com/tiendv89/agent-workflow/pull/32) | merged |

---

## New process lifecycle

```
Container start
  → runBootstrap()          once — clone/pull repos, validate agent.yaml, skill audit
  │
  └─ loop:
       → pullWorkspaces()   lightweight git fetch + reset --hard on each workspace
       → scan + claim + run (unchanged eligibility and claim protocol)
       → sleep idle_sleep_seconds
       → (repeat)
```

`idle_sleep_seconds: 0` exits after one cycle (single-shot mode — backwards compatible with external orchestrators).

---

## New config field

```yaml
# agent.yaml
idle_sleep_seconds: 60   # default when omitted; set 0 for single-shot mode
```

The field is **optional** — existing `agent.yaml` files without it continue to work (default 60 applies in code).

---

## New event types

| Event | Meaning |
|---|---|
| `poll_workspace_pulled` | Workspace git-pulled at start of cycle |
| `poll_git_halt` | Non-transient pull failure (auth/not-found/non-ff); workspace skipped this cycle |
| `poll_git_warn` | Transient pull failure (network); workspace skipped, retried next cycle |
| `activation_idle` | Nothing to do this cycle; sleeping `idle_sleep_seconds` |
| `activation_complete` | Task ran this cycle; sleeping `idle_sleep_seconds` before next |

---

## Log path change (T6)

Log files moved from a flat directory to per-task subdirectories:

| Before | After |
|---|---|
| `docs/features/<featureId>/logs/<taskId>_<safeIso>.jsonl` | `docs/features/<featureId>/logs/<taskId>/<safeIso>.jsonl` |

This is a path-only change. Log content and format are unchanged.

---

## Operator migration notes

### K8s: CronJob → Deployment (T3)

The `orchestration/kubernetes/cronjob.yaml` has been **replaced** by `orchestration/kubernetes/deployment.yaml`. A `kubectl apply` will fail because the resource kind changed; operators must:

```bash
# Delete the old CronJob first
kubectl delete cronjob agent-runtime -n agent-runtime

# Apply the new Deployment
kubectl apply -f agent-runtime/orchestration/kubernetes/deployment.yaml
```

### systemd: removed

The `orchestration/systemd/` directory has been removed. The timer-driven model is replaced by the continuous internal loop. Operators on systemd should migrate to Docker Compose (local) or K8s Deployment (production).

### Docker Compose

`restart: unless-stopped` is retained for crash recovery but is no longer the loop driver. The poll cadence is controlled by `idle_sleep_seconds` in `agent.yaml`.

---

## Test coverage

All 204 unit and integration tests pass. Key new test suites:

- `tests/agent-loop.test.ts` — 9 tests: single-shot mode, continuous mode, sleep timing, `activation_idle`/`activation_complete` events, default 60 s interval
- `tests/pull-workspaces.test.ts` — 19 tests: `classifyGitError` (halt vs warn), `pullWorkspaces` result array, workspace.yaml impl repo inclusion, error handling
