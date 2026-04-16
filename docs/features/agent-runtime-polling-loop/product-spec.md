# Product Specification

## Feature
- Feature ID: `agent-runtime-polling-loop`
- Title: Agent Runtime — Continuous Polling Loop

## Problem

The current agent runtime is a **single-shot process**: it runs one activation cycle (bootstrap → eligibility scan → claim → run → exit) and relies entirely on an external orchestrator to restart it.

In practice this creates three compounding problems:

1. **Docker restart backoff.** Under `restart: unless-stopped`, Docker tolerates a few rapid exits then applies exponential backoff. Once backoff kicks in, subsequent restarts emit no output — the container starts and exits before `bootstrap_ready` is written. The polling loop silently degrades.

2. **Rapid thrashing.** There is no idle sleep between cycles. On every idle activation the container exits immediately and Docker restarts it immediately, hammering the git server with a full clone/pull before finding no tasks again.

3. **Git repos re-cloned on every restart.** Because the container exits between activations, every restart re-clones all watched workspace repos from scratch. This is expensive and means the work done pulling the repo is thrown away on each cycle.

The design also assumed K8s CronJob as the production orchestrator. The actual production target is a **long-running K8s Deployment** (normal application), which has the same requirements as Docker Compose — the container must manage its own polling loop internally.

## Goals

- The agent container **stays running** between activation cycles; it does not exit on idle.
- Watched workspace repos are **cloned once** on first bootstrap (if not already present on the volume) and **`git pull`-ed** on each subsequent poll cycle — never re-cloned unless the volume is wiped.
- Poll interval is **configurable** via `agent.yaml` (`idle_sleep_seconds`). The exact default value will be decided during technical design.
- After a successful task run, the agent **sleeps the full `idle_sleep_seconds`** before re-polling (give the system a break before checking for newly unblocked tasks).
- `git pull` failures are handled by severity:
  - **Fatal** (exit): conflict, rejection (non-fast-forward), or 404/repo-not-found — these indicate a state the agent cannot safely recover from on its own.
  - **Retry next cycle**: transient network errors — agent logs a warning and continues polling.
- The existing **single-shot mode is preserved**: setting `idle_sleep_seconds: 0` causes the agent to exit after one cycle, keeping compatibility for any future use cases that need one-shot behavior.
- Both **Docker Compose (local)** and **K8s Deployment (production)** use the same continuous-loop container — no external scheduler needed.

## Non-goals

- Changing the claim protocol or task eligibility logic.
- Supporting heterogeneous toolchains inside the agent container (the agent does not build target repos — Claude subprocess handles that via tool calls in the implementation repo).
- Changing the semantics of `bootstrap_ready`, `no_eligible_tasks`, or `activation_idle` events — only the process lifecycle changes.
- Replacing K8s CronJob for any team that still uses it (single-shot mode covers this).
- Maintaining or updating systemd orchestration — the systemd timer+service pattern is removed from scope and will be deprecated.

## User story

> As a developer running `docker compose up` locally, I want the agent to keep running and automatically pick up newly ready tasks without me having to restart the container or configure any external scheduler.

> As a platform engineer deploying to Kubernetes, I want to run the agent as a standard long-running Deployment — not a CronJob — so it integrates naturally with our observability, rollout, and resource management tooling.

## Bundled bug fix

**`init-workspace` — `.env.template` sync direction is reversed.**

The current Check 3 in `init-workspace` reads keys from `.env` and writes them into `.env.template` automatically. This is wrong: `.env` contains real secrets and is never the source of truth for the template. The correct direction is `.env.template` → `.env` only. The fix must:
- Remove any logic that writes from `.env` → `.env.template` without human confirmation.
- Check 3 should only warn the operator when `.env` is missing keys that exist in `.env.template`, not the reverse.

This is a side fix bundled here for convenience; it does not affect the technical design of the polling loop.

## Acceptance criteria

Every change in this feature — code, config, and infrastructure — must be accompanied by updated documentation in the same PR. Specifically:

- **`agent.yaml.example`** — document `idle_sleep_seconds` with its default, valid range, and single-shot note.
- **`docker-compose.yml` comments** — remove or update the "Two long-running agent services. Each loops continuously" comment to accurately reflect the new loop model.
- **`README` / operator guide** (if one exists) — update any reference to Docker restart policy or CronJob as the loop driver.
- **K8s manifests** — replace CronJob with Deployment manifest; update any inline comments that reference single-shot activation.
- **`Quickstart.md`** — review and update any setup steps that reference restarting the container, external schedulers, or single-shot activation as the normal run mode.
- **`scripts/`** — audit all scripts; remove any that exist solely to support the single-shot/restart pattern (e.g. manual restart triggers, one-shot wrappers). Remaining scripts must be consistent with the continuous-loop model.
- **`init-workspace` skill (`SKILL.md`)** — correct the Check 3 description to reflect the fixed sync direction.

Documentation gaps are treated as incomplete work. A PR that ships code without matching doc updates must not be merged.
