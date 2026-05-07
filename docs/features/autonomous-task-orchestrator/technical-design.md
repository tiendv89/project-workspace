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
- Impl executor agents are unchanged — they continue to use `start-implementation` as today.
- `handleDraftReviews` is removed; the `change_requested` task status replaces it as the signal for comment resolution work.

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

The orchestrator reads task YAMLs and dispatches agents based purely on task status — it never calls the GitHub API directly. GitHub state (CI checks, PR reviews) is read by the reviewer agent inside its own executor, which then writes its verdict back to the task YAML.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│          Orchestrator — new concerns added to runOneCycle         │
│          Task YAML status is the only dispatch signal             │
│                                                                   │
│  Each poll cycle:                                                 │
│                                                                   │
│  status=ready           ──▶ impl agent    (kind=impl)             │
│  status=change_requested ──▶ fix agent    (kind=impl)             │
│  status=in_review        ──▶ reviewer     (kind=review)           │
│                                │                                  │
│                          reap loop                                │
│                                │                                  │
│             ┌──────────────────┼──────────────────┐              │
│             ▼                  ▼                  ▼              │
│       kind=impl          kind=review         (unchanged)          │
│       → in_review        → passed            → blocked            │
│         or blocked       → change_requested                       │
│                          → escalate                               │
│             │                  │                  │              │
│             │            ┌─────┴──────┐     ┌────┴──────┐       │
│             │            │ Auto-Done  │     │ Escalation│       │
│             │            │ Writer     │     │ Handler   │       │
│             │            │ done +     │     │ Slack +   │       │
│             │            │ cascade    │     │ blocked   │       │
│             │            └────────────┘     └───────────┘       │
│             │                                                     │
│             └──▶ next cycle picks up change_requested             │
└──────────────────────────────────────────────────────────────────┘
```

## Component Designs

### Task Graph Poller
Reads all `tasks/*.yaml` files each cycle and routes by status:

| Status | Action |
|---|---|
| `ready` | Dispatch impl agent |
| `change_requested` | Dispatch fix agent |
| `in_review` | Dispatch reviewer agent |
| `in_progress` | Skip — agent already running |
| `done` / `blocked` / `cancelled` | Skip |

No in-memory table is consulted — task YAML status is the only signal.

### Dispatch Controller

A new concern inside the existing `runOneCycle`, alongside `handleMergedPrs`. `handleDraftReviews` is **removed** — its role is replaced by the explicit `change_requested` status and fix agent dispatch described below.

**Claim protocol (all agent kinds):** Write a log entry to the task YAML and push (first-push-wins). If the push is rejected, another orchestrator instance claimed first — skip. Task YAML `in_progress` status is the canonical ownership record.

| Agent kind | Triggered by status | Claim log action | Sets status to | broker `kind` |
|---|---|---|---|---|
| Impl agent | `ready` | `claimed` | `in_progress` | `impl` |
| Fix agent | `change_requested` | `fix_started` | `in_progress` | `impl` |
| Reviewer | `in_review` | `reviewer_started` | — (stays `in_review`) | `review` |

**Concurrency guard:** `broker.registrySize() >= max_concurrent` — same guard as the existing executor pool check.

**Completion:** Drained by the shared reap loop. Both `kind=impl` completions (impl and fix agents) route to `dispatchExecutorResult` (modified — see Max-Turns Retry below). `kind=review` completions route to a new `dispatchReviewResult` handler.

**Max-turns retry:** When `dispatchExecutorResult` receives `terminal_status: blocked` and `blocked_reason` starts with `max_turns`, it checks the task log before writing `blocked`:

1. Count log entries with `action: retried` in the task YAML.
2. If count < `MAX_TASK_RETRIES` (default `3`): write a `retried` log entry (with the attempt number and original `blocked_reason`), reset status to `ready`, push — the task re-enters the dispatch queue on the next cycle.
3. If count ≥ `MAX_TASK_RETRIES`: write `blocked` as normal and route to the Escalation Handler.

All other `blocked_reason` values (e.g. `executor_failed`, agent-written reasons) bypass the retry logic and go straight to `blocked`.

`MAX_TASK_RETRIES` is read from the orchestrator environment via `EXECUTOR_MAX_RETRIES` (default `3` when absent).

### Reviewer Agent

Dispatched when task status is `in_review`. Submitted with `kind=review`.

**Claim guard:** Skip if the last log entry action is `reviewer_started` (another instance already claimed this review cycle).

**Cycle limit:** Before acting, the reviewer counts `in_review` log entries in the task YAML. If the count is already ≥ `MAX_REVIEW_CYCLES` (default: `3`), write `terminal_status: escalate` immediately — do not post another change request. This prevents the `in_review → change_requested → in_progress → in_review` loop from running indefinitely.

`MAX_REVIEW_CYCLES` is read from the executor environment. The orchestrator passes it when building the reviewer briefing env, sourced from `REVIEWER_MAX_CYCLES` in the agent/workspace config (default `3` when absent).

**Reviewer logic (inside the executor):**

1. Read the PR diff, task spec, and technical design.
2. Check GitHub CI: `GET /repos/{owner}/{repo}/commits/{ref}/check-runs` — wait for resolution.
3. Evaluate the diff against the rubric (see below).
4. **Decision:**
   - Cycle count ≥ `MAX_REVIEW_CYCLES` → write `terminal_status: escalate` (loop guard — checked first, before any other condition)
   - CI passes + rubric passes → post `APPROVE` review to GitHub, write `terminal_status: passed`
   - CI passes + issues found → post `REQUEST_CHANGES` review with inline comments, write `terminal_status: change_requested` + review URL in notes
   - CI fails (broken tests, compile error) → post `REQUEST_CHANGES` review with CI failure summary, write `terminal_status: change_requested` + review URL in notes

**Skill:** The reviewer executor runs `/review-pr` — a new skill to be created alongside this feature. The skill encapsulates the full review criteria so it can also be invoked manually by a human. The orchestrator briefing says "run `/review-pr`" with task context, exactly as respond-to-review briefings say "run `/respond-to-review`".

**Rubric (full criteria in the skill's `references/review_criteria.md`):**

The skill evaluates criteria in priority order — a finding in an earlier category supersedes later ones:

1. **Correctness** — bugs, logic errors, null handling, race conditions, edge cases
2. **Security** — injection, auth/authz gaps, secrets, input validation
3. **Performance** — N+1 queries, blocking I/O, O(n²) loops
4. **Design / architecture** — single responsibility, DRY, matches existing patterns
5. **Style and conventions** — linter compliance, naming, formatting

**Feedback severity → GitHub review decision:**

| Severity | Marker | Reviewer action |
|---|---|---|
| Blocker (correctness, security) | 🔴 | `REQUEST_CHANGES` — must fix before merge |
| Important (performance, design) | 🟡 | `REQUEST_CHANGES` — should fix |
| Nit / suggestion | 🟢 💡 | Inline comment only; still `APPROVE` if no blockers |
| No issues | — | `APPROVE` |

The PR is approved if and only if there are zero 🔴 or 🟡 findings. Nits are posted as comments but do not block approval.

**Result routing:** The reap loop calls `dispatchReviewResult` for `kind=review` completions:

| `terminal_status` | Orchestrator action |
|---|---|
| `passed` | Auto-Done Writer: write `done` log entry + auto-ready cascade |
| `change_requested` | Mutate task YAML to `change_requested` + log review URL; fix agent picks it up next cycle |
| `escalate` | Escalation Handler: Slack message + mutate task to `blocked` |

### Fix Agent

Dispatched when task status is `change_requested`. Submitted with `kind=impl` (same result contract as the impl agent).

**Claim:** Writes `fix_started` log entry, sets status to `in_progress`, pushes (first-push-wins).

**Fix logic (inside the executor):**

1. Read the `REQUEST_CHANGES` review URL from the task log entry written by the reviewer.
2. Read each review comment from the GitHub API.
3. For each comment: address the issue in code, push the fix commit, mark the comment as resolved via GitHub API.
4. Push all fix commits to the task branch.
5. Write `result.json` with `terminal_status: in_review`.

The task returns to `in_review` and the reviewer runs again on the next cycle. If the reviewer finds the fixes acceptable, it approves and the task reaches `done`. If not, it posts a new `REQUEST_CHANGES` — and when the cycle counter reaches `MAX_REVIEW_CYCLES` the next reviewer dispatch will escalate instead.

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

## Task YAML Schema Changes

### New status: `change_requested`

Add `change_requested` to the valid task status values:

```
todo | ready | in_progress | blocked | in_review | change_requested | done | cancelled
```

### New status transitions

```
in_review → change_requested   (reviewer agent, when REQUEST_CHANGES posted)
in_review → done               (reviewer agent, when CI + rubric pass)
change_requested → in_progress (fix agent claims)
```

The existing `in_review → done` (human) and `in_review → blocked` (human) transitions are unchanged.

### New `execution.actor_type` value

```yaml
execution:
  actor_type: human | agent | either | orchestrator
```

### New log entry actions

| Action | Written by |
|---|---|
| `reviewer_started` | Orchestrator (claim entry before reviewer dispatch) |
| `fix_started` | Orchestrator (claim entry before fix agent dispatch) |
| `retried` | Orchestrator (max-turns retry — resets task to `ready`; note includes attempt number and original `blocked_reason`) |

### CLAUDE.md transition rule additions

```
in_review → change_requested   (reviewer agent only)
in_review → done               (human, or reviewer agent when CI + rubric pass)
change_requested → in_progress (fix agent — same first-push-wins claim as ready → in_progress)
```

## Dependency Analysis

- Depends on existing task YAML schema — adds `change_requested` status and new log actions.
- Requires a new `review-pr` skill (`workflow/technical_skills/review-pr/`) with `references/review_criteria.md` carrying the full evaluation rubric.
- `handleDraftReviews` (`dispatch-draft-review.ts`) is **removed** by this feature.
- GitHub API (CI checks, PR reviews) is called by the reviewer executor, not the orchestrator — no new orchestrator-level auth required.
- Depends on Claude API for the reviewer executor (uses existing `ANTHROPIC_API_KEY`).
- Depends on Slack webhook for escalation (new config value: `SLACK_WEBHOOK_URL`).
- `REVIEWER_MAX_CYCLES` — optional env var controlling the review loop limit (default `3`). Must be documented in `.env.template`.
- `EXECUTOR_MAX_RETRIES` — optional env var controlling the max-turns retry limit (default `3`). Must be documented in `.env.template`.
- Impl executor agents are unchanged; fix agents reuse the same `kind=impl` result contract with a different briefing.

## Parallelization / Blocking Analysis

External dependencies: none blocking. `ANTHROPIC_API_KEY` and `GITHUB_TOKEN` are already assumed present; Slack webhook is optional until T6.

```
T1: Schema + CLAUDE.md — add `change_requested` status, new log actions
    (`reviewer_started`, `fix_started`, `retried`), new transitions,
    `.env.template` entries for REVIEWER_MAX_CYCLES / EXECUTOR_MAX_RETRIES /
    SLACK_WEBHOOK_URL. Remove handleDraftReviews from orchestrator.
  └── Can begin now — no blockers

T7: Orchestrator config — workspace.yaml entries for the new env vars above
  └── Can begin now — no blockers
  └── T1 and T7 run in parallel

  T2: Dispatch controller — poller routing table (ready→impl,
      change_requested→fix, in_review→reviewer), claim log actions,
      max-turns retry logic in dispatchExecutorResult, skeleton
      dispatchReviewResult handler, concurrency guard
      └── BLOCKED on T1 (change_requested status and log actions must be
          frozen before the routing table and claim entries are implemented)

    T3: review-pr skill — create workflow/technical_skills/review-pr/ with
        references/review_criteria.md, CI check logic, rubric evaluation,
        GitHub APPROVE / REQUEST_CHANGES posting, cycle limit via
        MAX_REVIEW_CYCLES env var, writes result.json
        └── BLOCKED on T1 (reviewer_started log action and result schema
            must be settled)
        └── Can run in parallel with T2 once T1 is done

    T4: Fix agent — briefing template for fix-agent executor, dispatch from
        change_requested status, reads REQUEST_CHANGES review URL from task
        log, addresses comments, pushes, returns terminal_status: in_review
        └── BLOCKED on T2 (fix agent dispatch hooks into T2's routing table
            and claim protocol)

    T5: Auto-done writer — on dispatchReviewResult terminal_status=passed:
        write done log entry + auto-ready cascade + push to feature branch
        └── BLOCKED on T2 (dispatchReviewResult skeleton must exist)
        └── Can run in parallel with T4

    T6: Escalation handler — on dispatchReviewResult terminal_status=escalate:
        Slack webhook message + mutate task to blocked + blocked_reason
        └── BLOCKED on T2 (dispatchReviewResult skeleton must exist)
        └── Can run in parallel with T4 and T5
```
