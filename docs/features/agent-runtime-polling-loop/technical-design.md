# Technical Design — Agent Runtime: Continuous Polling Loop

## 1. Current state

### What exists today

The agent runtime is a **single-shot Node.js process**:

```
Container start
  → runBootstrap()   (clone/pull repos + validate agent.yaml)
  → main() scan loop (one pass over watched workspaces)
  → claim + run-claude (if task found)
  → process.exit(0)
```

External orchestrators drive re-activation:
- **Docker Compose** (local): `restart: unless-stopped` restarts the container on every exit
- **Kubernetes**: CronJob fires every 5 minutes (`schedule: "*/5 * * * *"`, `concurrencyPolicy: Forbid`)
- **systemd**: `agent-runtime.timer` fires every 5 minutes; `agent-runtime.service` is `Type=oneshot`

### Current constraints

- `run-once.sh` is the container entrypoint (named for single-shot semantics)
- `runBootstrap()` in `bootstrap.ts` runs on every activation — includes full clone-or-pull of all repos and a skill reference audit
- `main()` in `main.ts` scans all watched workspaces once and exits; there is no internal retry or sleep
- `idle_sleep_seconds` does not exist in the config schema or `AgentConfig` interface
- `agent.schema.json` uses `additionalProperties: false` — any new field must be explicitly added to the schema

### Current limitations

1. **Docker restart backoff.** `restart: unless-stopped` restarts on exit 0, but Docker applies exponential backoff after repeated rapid exits. After the first full cycle, Docker restarts the container too fast for it to emit even `bootstrap_ready` before its next exit — subsequent restarts show only `exited with code 0` with no log output. The loop silently degrades.

2. **No throttle.** Without idle sleep, the container hammers the git server with a full clone-or-pull every few seconds between restarts.

3. **Git repos re-cloned on every restart.** Even though `syncRepo()` in `bootstrap.ts` already does clone-or-pull (clone if missing, `git fetch + reset --hard` if present), the container exits and is restarted as a fresh process, so the git objects are re-fetched from the network on every cycle.

4. **CronJob is not the production deployment model.** The production target is a long-running K8s **Deployment**, not a CronJob. The existing `cronjob.yaml` and `Type=oneshot` systemd service reflect an outdated assumption.

---

## 2. Problem framing

### What specifically needs to change

- `main.ts` must run a **continuous polling loop** rather than exiting after one scan.
- The **bootstrap runs once** at process startup. Per-poll-cycle git work is a lightweight workspace pull (not a full bootstrap).
- A new `idle_sleep_seconds` config field controls the interval between idle cycles.
- The K8s `cronjob.yaml` is replaced with a `deployment.yaml`.
- The systemd service changes from `Type=oneshot` (timer-driven) to a long-running service (timer removed).
- All docs and support scripts are updated to reflect the new lifecycle.

### What must remain stable

- The claim protocol (git SHA-based contention) — unchanged.
- Task eligibility logic — unchanged.
- Structured JSON event output (`bootstrap_ready`, `no_eligible_tasks`, `activation_idle`, `task_claimed`, etc.) — unchanged in semantics; only the frequency and process lifecycle changes.
- Single-shot compatibility: `idle_sleep_seconds: 0` exits after one cycle. External orchestrators that still want single-shot behaviour set this flag.
- The `restart: unless-stopped` policy in `docker-compose.yml` stays — it is still needed for crash recovery, just no longer the sole driver of the loop.

### Fixed assumptions

- All implementation repos live in the `workflow` repo (id: `workflow` in workspace.yaml).
- `bootstrap.ts`'s `syncRepo()` is already correct (clone vs pull) — it is reused, not rewritten.
- The AJV schema validator uses `additionalProperties: false`, so any new field must be added to `agent.schema.json`.

---

## 3. Options considered

### Option A — External orchestration only (status quo, improved)

Add a sleep shim in `run-once.sh` so Docker restart backoff is avoided:
```bash
node dist/main.js "$@" || true
sleep 60
```

**Pros:** Minimal code change.  
**Cons:** Git repos are still re-cloned on every restart (the sleep only reduces frequency). Docker restart backoff is mitigated but not eliminated. K8s and systemd are still CronJob/timer models. The "loop" remains externally driven with no configurability inside the agent itself.

**Verdict: rejected.** Does not address git re-clone cost or the K8s Deployment requirement.

---

### Option B — Internal polling loop (chosen)

Refactor `main.ts` to run a `while(true)` polling loop. Bootstrap runs once at process start. Each poll cycle does a lightweight workspace pull, scans for tasks, claims and runs if found, then sleeps `idle_sleep_seconds` before the next cycle.

**Pros:**
- Container stays running — Docker restart backoff is eliminated.
- Git repos are cloned once and pulled on each cycle (cheap network operation vs full clone).
- Poll interval is explicit, configurable, and logged.
- Works identically under Docker Compose, K8s Deployment, and systemd long-running service.
- `idle_sleep_seconds: 0` preserves single-shot compatibility for any external orchestrator that needs it.

**Cons:**
- If the process crashes, the polling loop dies (Docker restart recovers it, but adds one restart latency).
- Slightly more complex `main.ts` (one level of nesting added).

**Verdict: chosen.**

---

## 4. Chosen design

### Process lifecycle (new)

```
Container start
  → runBootstrap()          once — clone/pull repos, validate agent.yaml, skill audit
  │
  └─ loop:
       → pullWorkspaces()   lightweight git fetch + reset --hard on each watched workspace
       → scan + claim + run (existing logic, unchanged)
       → sleep idle_sleep_seconds
       → (repeat)
```

When `idle_sleep_seconds: 0`:
```
Container start
  → runBootstrap()
  → runOneCycle()
  → process.exit(0)         single-shot mode — external orchestrators use this
```

### New config field: `idle_sleep_seconds`

Added to `agent.schema.json` (optional integer ≥ 0) and `AgentConfig` interface:

```yaml
# agent.yaml
idle_sleep_seconds: 60     # sleep 60 s between idle cycles (default when omitted)
                           # set to 0 for single-shot mode (external orchestrator drives cadence)
```

The default when the field is absent is **60 seconds** (resolved in code: `config.idle_sleep_seconds ?? 60`).

### Per-cycle workspace pull

A new `pullWorkspaces()` function runs at the top of each poll cycle **before** the eligibility scan. It must cover:

1. `git fetch + reset --hard` on each watched workspace URL (management repos).
2. `git fetch + reset --hard` on each implementation repo declared under `repos[]` in each watched workspace's `workspace.yaml` — not just the management repos.

It does NOT re-sync the workflow repo (that only changes on deploy, handled at bootstrap).

> **Note:** The exact point in the current codebase where implementation repos are cloned/pulled should be verified during T2 implementation before writing `pullWorkspaces()`, to avoid duplicating or conflicting with existing sync logic.

**Git pull error classification:**

The process never exits due to a git pull failure — exiting would just trigger a pod/container restart that immediately hits the same error (CrashLoopBackOff on K8s, restart loop on Docker). Instead, errors are classified by severity and affect log verbosity only; the loop always continues.

| Error type | Behaviour |
|---|---|
| Non-fast-forward / remote rejection | **Halt-and-warn** — emit `poll_git_halt`, skip the affected workspace this cycle, sleep full interval, retry next cycle. Operator action required to resolve the repo state. |
| 404 / repo not found / auth failure | **Halt-and-warn** — emit `poll_git_halt`, skip the affected workspace this cycle, sleep full interval, retry next cycle. |
| Network timeout / connection reset / DNS failure | **Soft-warn** — emit `poll_git_warn`, skip cycle, sleep, retry next cycle. |

Classification is done by matching `stderr` output from the git subprocess against known error strings. In all cases the polling loop remains running.

### After a successful task run

After `runClaude()` completes, the agent sleeps the full `idle_sleep_seconds` before re-polling. This gives the system time to process the task result (e.g. dependency unblocking via human review) before the next scan.

### Affected repositories

| Repo id | Changes |
|---|---|
| `workflow` | All changes — `main.ts`, `bootstrap.ts`, schema, config, orchestration manifests, docs, scripts |

### Compatibility

- `idle_sleep_seconds` is **optional** in the schema. Existing `agent.yaml` files without it continue to work (default of 60 applies).
- Exit codes are unchanged (0 = normal, 2 = config invalid, 3 = git failed, 4 = unexpected).
- Single-shot mode (`idle_sleep_seconds: 0`) preserves full backwards compatibility for external orchestrators.

### K8s: CronJob → Deployment

`orchestration/kubernetes/cronjob.yaml` is replaced by `orchestration/kubernetes/deployment.yaml`. The Namespace, PVC, ConfigMap (with updated `agent.yaml` including `idle_sleep_seconds`), and Secret are preserved. The CronJob-specific fields (`schedule`, `concurrencyPolicy`, `backoffLimit`, `restartPolicy: Never`) are removed. `restartPolicy: Always` (Deployment default) takes over crash recovery.

### systemd: removed from scope

The systemd orchestration (`agent-runtime.service` + `agent-runtime.timer`) is deprecated and removed. It was designed exclusively for the external one-shot pattern. With the container now managing its own polling loop, there is no need for a timer-driven host-level scheduler. Operators previously using systemd should migrate to Docker Compose (local) or K8s Deployment (production). The systemd files will be removed from the repo.

---

## 5. Dependency analysis

| Dependency | Status | Notes |
|---|---|---|
| `idle_sleep_seconds` in schema | Internal | T1 — must land before T2 reads the field |
| `syncRepo()` export from `bootstrap.ts` | Internal | Already exists; may need to be exported if not already |
| K8s Deployment manifest | Internal | T3 — independent of TypeScript changes |
| `init-workspace` SKILL.md fix | Internal | T5 — fully independent; no blockers |
| AJV `additionalProperties: false` | Existing constraint | New field must appear in schema properties list |
| Docker Compose `restart: unless-stopped` | Retained | Still needed for crash recovery; no longer the loop driver |

No unresolved external dependencies.

---

## 6. Parallelization / blocking analysis

```
T1: Schema + AgentConfig interface (workflow repo)
T3: K8s Deployment manifest + systemd removal (workflow repo)
T5: init-workspace Check 3 bug fix (workflow repo)
T6: Log path restructure — per-task subdirectory (workflow repo)
  └── T1, T3, T5, T6 run in parallel — Can begin now, no blockers

T2: Continuous polling loop refactor in main.ts (workflow repo)
  └── BLOCKED on T1 (idle_sleep_seconds must be in AgentConfig before main.ts can read config.idle_sleep_seconds)

T4: Documentation update — QUICKSTART.md, DOCKER.md, docker-compose.yml, bootstrap-agent-host.sh (workflow repo)
  └── BLOCKED on T2 (loop behavior, new config field, and event names must be settled before docs are updated)
  └── BLOCKED on T3 (orchestration section of QUICKSTART must reference Deployment, not CronJob)
```

---

## 7. Repository impact

All changes are in the `workflow` repo. No other repo is touched.

| Area | Files affected |
|---|---|
| Config schema | `schemas/agent.schema.json` |
| TypeScript interface | `src/config/validate-agent-yaml.ts` |
| Runtime logic | `src/main.ts`, `src/bootstrap/bootstrap.ts` (export `syncRepo`) |
| Entrypoint script | `scripts/run-once.sh` (comment update; name retained for backwards compat) |
| Local orchestration | `orchestration/local/docker-compose.yml`, `orchestration/local/agent.yaml.example` |
| K8s orchestration | `orchestration/kubernetes/cronjob.yaml` (replaced by `deployment.yaml`) |
| systemd orchestration | `orchestration/systemd/` (entire directory removed) |
| Docs | `QUICKSTART.md`, `DOCKER.md`, `docs/OPERATOR-GUIDE.md`, `docs/TROUBLESHOOTING.md` |
| Setup script | `scripts/bootstrap-agent-host.sh` |
| Workflow skill | `workflow_skills/init-workspace/SKILL.md` |

---

## 8. Validation and release impact

### Testing expectations

- Existing unit tests for `bootstrap.ts`, `validate-agent-yaml.ts`, and eligibility/claim logic are unchanged.
- New unit tests for the polling loop: idle sleep, single-shot (`idle_sleep_seconds: 0`), git pull error classification (fatal vs retryable), and post-task sleep.
- Manual smoke test: run `docker compose up` locally, confirm `bootstrap_ready` appears once, then `no_eligible_tasks` → sleep → `no_eligible_tasks` cycles at the configured interval.

### Migration / config impact

- `agent.yaml` files without `idle_sleep_seconds` continue to work (field is optional; default 60 applies in code).
- K8s operators using `cronjob.yaml` must migrate to `deployment.yaml`. The old CronJob manifest should be removed from the repo to avoid confusion; operators should `kubectl delete cronjob agent-runtime` before applying the new Deployment.
- systemd operators must migrate to Docker Compose or K8s Deployment. The `orchestration/systemd/` directory will be removed from the repo; a deprecation notice will be added to `QUICKSTART.md`.

### Rollout concerns

- The Docker image is backwards-compatible: an old `agent.yaml` (without `idle_sleep_seconds`) works fine with the new image.
- Operators upgrading from single-shot to continuous mode should set `idle_sleep_seconds: 60` explicitly in `agent.yaml` to make intent clear.
- The rename from CronJob to Deployment changes K8s resource kind — a plain `kubectl apply` will fail; operators must delete the old CronJob first.

### Backward compatibility

`idle_sleep_seconds: 0` preserves single-shot behaviour for any team that still wants external orchestration to drive cadence. No breaking changes to the config schema (additive only).
