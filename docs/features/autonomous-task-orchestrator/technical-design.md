# Technical Design

## Feature
- Feature ID: `autonomous-task-orchestrator`
- Title: Autonomous Task Orchestrator

## Current State

The workflow system manages features through a lifecycle of stages (in_design → in_tdd → ready_for_implementation → in_implementation → in_handoff → done). Within a feature, tasks are stored as individual YAML files under `docs/features/<feature_id>/tasks/`, each with a status state machine.

Currently, after a human approves a task breakdown, executor agents pick up `ready` tasks via `start-implementation`, do the work, open PRs, and set status to `in_review`. At that point, a **human** must review the PR, mark the task `done`, and trigger the auto-ready cascade for dependent tasks. This human step is the bottleneck.

## Constraints

- Must not break existing task YAML schema — the orchestrator is a new consumer, not a new schema owner.
- The `done` transition remains human-authoritative for escalated tasks — the orchestrator only applies it when CI + reviewer agent both pass.
- All existing branch, rebase, and management repo write rules in `CLAUDE.md` apply to orchestrator-initiated commits.
- The orchestrator must not dispatch two agents to the same task concurrently.
- Executor agents are unchanged — they continue to use `start-implementation` as today.

## Options Considered

### Option A — Polling daemon (stateless, file-based)
The orchestrator polls task YAMLs on a fixed interval. All state lives in the task files. The daemon is stateless between polls.

- Pros: simple, crash-safe (restarts are safe), no new database, consistent with existing file-based state model
- Cons: latency proportional to poll interval; slightly inefficient for large task graphs

### Option B — Event-driven (GitHub webhooks)
Webhooks from GitHub (PR events, CI events) trigger orchestrator logic in real time.

- Pros: real-time response, no polling overhead
- Cons: requires a public webhook endpoint, adds infrastructure complexity, webhook delivery is not guaranteed

### Option C — Hybrid (poll task state, webhook for CI/PR events)
Task graph polling stays file-based; CI and PR state transitions are webhook-triggered.

- Pros: real-time quality gate, simple state source
- Cons: more complex than Option A, still requires webhook endpoint

## Chosen Design

**Option A — Polling daemon.**

Consistency with the existing file-based state model outweighs the polling latency cost. A 30-second poll interval is acceptable for autonomous feature execution (features take hours, not seconds). This also means the orchestrator is trivially restartable and requires zero new infrastructure beyond a process host.

The orchestrator will be implemented as a Node.js or Python daemon invoked by the agent runtime's scheduler. It reads task YAMLs, dispatches executor agents via the existing `start-implementation` contract, and polls the GitHub API for CI/PR status rather than requiring inbound webhooks.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Orchestrator Daemon                   │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Feature Branch Lifecycle Manager                │   │
│  │  (on start: create/sync feature/{feature_id},    │   │
│  │   record base SHA in status.yaml)                │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  ┌──────────────┐    ┌───────────────┐                  │
│  │  Task Graph   │    │  Dispatch     │                  │
│  │  Poller       │───▶│  Controller   │──▶ executor agent│
│  │  (30s loop)   │    │               │    (start-impl)  │
│  └──────────────┘    └───────┬───────┘                  │
│                              │                           │
│                    ┌─────────▼────────┐                  │
│                    │  Quality Gate    │                   │
│                    │  Service         │                   │
│                    │  CI poll +       │                   │
│                    │  Reviewer Agent  │                   │
│                    └─────────┬────────┘                  │
│                              │                           │
│                    ┌─────────▼────────┐                  │
│                    │  Auto-Done       │                   │
│                    │  Writer          │                   │
│                    │  (mgmt repo)     │                   │
│                    └─────────┬────────┘                  │
│                    ┌─────────▼────────┐                  │
│                    │  Handoff Trigger │                   │
│                    │  (all tasks done)│                   │
│                    │  handoff.md +    │                   │
│                    │  feature PR open │                   │
│                    └─────────┬────────┘                  │
│                              │ escalate                  │
│                    ┌─────────▼────────┐                  │
│                    │  Escalation      │                   │
│                    │  Handler         │                   │
│                    │  (Slack webhook) │                   │
│                    └──────────────────┘                  │
└─────────────────────────────────────────────────────────┘
```

## Component Designs

### Task Graph Poller
- Reads all `tasks/*.yaml` files for the target feature on each tick.
- Computes which tasks are `ready` with all `depends_on` satisfied (`done`).
- Skips tasks already claimed (has an in-flight agent entry in the dispatch table).
- Emits `dispatch` events for eligible tasks.

### Dispatch Controller
- Maintains an in-memory dispatch table: `{ task_id → agent_handle }`.
- Before dispatching, writes a claim entry to the task YAML log (`action: claimed, by: orchestrator`) and pushes to the management repo — this is the canonical ownership record.
- Invokes the executor agent via the existing runtime interface.
- Monitors agent completion (polling agent status or reading task YAML for `in_review` transition).

### Quality Gate Service
Activates when a task transitions to `in_review`.

1. **CI polling**: calls GitHub API `GET /repos/{owner}/{repo}/commits/{ref}/check-runs` every 60 seconds until all checks resolve.
2. **Reviewer agent**: invokes a Claude API call with PR diff + task spec + technical design. Returns `{ verdict: pass|flag|fail, confidence: float, notes: string }`.
3. **Decision**:
   - `CI pass` + `reviewer pass` + `confidence ≥ threshold` → auto-done path
   - Any `fail` → retry (up to `max_retries`) → escalate
   - Any `flag` → escalate immediately (no retry)

### Reviewer Agent
Claude API call (claude-sonnet-4-6) with:
- System: reviewer persona, evaluation rubric
- User: PR diff, task spec excerpt, technical design excerpt
- Response schema: structured JSON `{ verdict, confidence, notes }`

The rubric evaluates:
- Does the implementation match the task spec?
- Are there obvious correctness issues (wrong API, missing error handling, broken tests)?
- Does it introduce regressions visible in the diff?

### Auto-Done Writer
When the quality gate passes:
1. Follows branch checkout + sync protocol on the management repo.
2. Writes `done` log entry to the task YAML (`actor: orchestrator`, real timestamp).
3. Runs auto-ready cascade: finds tasks whose `depends_on` are now all `done`, transitions them `todo → ready`, appends log entries.
4. Commits all changes and pushes to the feature branch.

### Escalation Handler
- Sends a Slack webhook message with: feature ID, task ID, reason, PR URL, suggested action.
- Marks task `blocked` in the YAML with `blocked_reason` and `blocked_suggestion`.
- The human resolves the block and the orchestrator resumes on the next poll.

### Feature Branch Lifecycle Manager

Runs at orchestrator start, before the main dispatch loop.

The orchestrator must be idempotent — the branch may already exist if the orchestrator was restarted or the branch was created manually.

```
git fetch origin

if origin/feature/{feature_id} exists:
    # Branch already exists — resume, do not reset
    git checkout feature/{feature_id}
    if git pull origin feature/{feature_id} fails (non-fast-forward / force-pushed):
        # Remote was force-pushed; discard stale local branch and re-checkout clean
        git checkout {base_branch}
        git branch -D feature/{feature_id}
        git checkout -b feature/{feature_id} origin/feature/{feature_id}
    # If status.yaml already has feature_branch_base_sha set, keep it (do not overwrite)
    # If feature_branch_base_sha is unset, compute the merge-base and record it:
    #   BASE_SHA=$(git merge-base feature/{feature_id} origin/{base_branch})
else:
    # Branch does not exist — create from base branch tip
    git checkout {base_branch} && git pull origin {base_branch}
    BASE_SHA=$(git rev-parse HEAD)
    git checkout -b feature/{feature_id}
    git push -u origin feature/{feature_id}
    # Record BASE_SHA in status.yaml as feature_branch_base_sha
```

`feature_branch_base_sha` is the merge-base of the feature branch and the base branch at first creation. The drift detector (from `autonomous-feature-reviewer`) uses this SHA as its comparison baseline — "what was on main when this feature started." It must never be overwritten on restart.

**Task PR target:** The orchestrator passes `base: feature/{feature_id}` when creating task PRs via the GitHub API. No change to executor agents — they open PRs as today; the orchestrator controls the PR target.

### Handoff Trigger

Activates when the Auto-Done Writer transitions the last task to `done`.

1. Generate `handoffs/handoff.md` in the management repo (see structure below).
2. Open a PR: `feature/{feature_id}` → `{base_branch}` via GitHub API.
3. Write the PR URL into `status.yaml` under `stages.handoff` and `handoff_pr_url`.
4. Transition `feature_status` to `in_handoff`, `current_stage` to `handoff`.
5. Commit and push management repo changes on the feature branch.
6. Notify operator via escalation channel.

### Handoff Document Structure

```markdown
# Handoff — {feature_title}

## Summary
{1-3 sentence summary derived from product spec goals}

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — {title} | {pr_url} | {reviewer_agent_notes} |
...

## Deviations from Technical Design
{list of any deviations noted by executor agents or reviewer agent}

## Files Changed
{aggregate file list across all task PRs}

## Follow-up Items
{open risks or flagged items from reviewer agent notes}

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| Task T1 done | orchestrator | {ts} |
...
```

## Task YAML Schema Changes

Add `orchestrator` as a valid actor in `execution.actor_type`:

```yaml
execution:
  actor_type: human | agent | either | orchestrator
```

The `done` transition rule is relaxed:

> `in_review → done` (human, **or orchestrator when CI pass + reviewer agent pass**)

No other schema changes.

## Dependency Analysis

- Depends on existing task YAML schema (stable, no changes required beyond actor type).
- Depends on GitHub API for CI status, PR diff, PR creation (feature branch PR), and branch compare. Uses existing `GITHUB_TOKEN`.
- Depends on Claude API for reviewer agent. Uses existing `ANTHROPIC_API_KEY`.
- Depends on Slack webhook for escalation. New config value: `SLACK_WEBHOOK_URL`.
- Depends on management repo SSH write access for feature branch creation, status.yaml updates, and handoff doc commit. Uses existing `SSH_KEY_PATH`.
- Executor agents are unchanged.
- `autonomous-feature-reviewer` is a downstream consumer — it activates on features this orchestrator moves to `in_handoff`. No build dependency; both can be built in parallel.

## Parallelization / Blocking Analysis

Tasks T1 (poller + dispatch), T2 (quality gate), T3 (reviewer agent), and T4 (auto-done writer) form the critical path and must be built in order.

T5 (escalation handler) can be built in parallel with T2–T4 — it only requires the dispatch controller interface from T1.

T6 (feature branch lifecycle manager + handoff trigger) depends on T4 (auto-done writer) for the handoff trigger, but branch creation logic can be built in parallel with T1.

T7 (schema + CLAUDE.md update) and T8 (orchestrator config in workspace.yaml) are independent and can be done in parallel with T1.
