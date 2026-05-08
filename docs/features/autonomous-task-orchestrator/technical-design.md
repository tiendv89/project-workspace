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
│                    Orchestrator Daemon                             │
│                                                                   │
│  On start (once):                                                 │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Feature Branch Lifecycle Manager                          │  │
│  │  create/sync feature/{feature_id}, record base SHA,        │  │
│  │  open draft PR on first creation                           │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  Each poll cycle (30s):                                           │
│                                                                   │
│  status=ready            ──▶ impl agent    (kind=impl)            │
│  status=change_requested ──▶ fix agent     (kind=impl)            │
│  status=in_review        ──▶ reviewer      (kind=review)          │
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
│             │            └─────┬──────┘     └───────────┘       │
│             │                  │ all tasks done                  │
│             │            ┌─────▼──────┐                          │
│             │            │  Handoff   │                          │
│             │            │  Trigger   │                          │
│             │            │  handoff.md│                          │
│             │            │  + feature │                          │
│             │            │  PR open   │                          │
│             │            └────────────┘                          │
│             │                                                     │
│             └──▶ next cycle picks up change_requested             │
└──────────────────────────────────────────────────────────────────┘
```

## Component Designs

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

# Open draft PR — idempotent (skip if handoff_pr_url already set in status.yaml):
if status.yaml.handoff_pr_url is null:
    POST /repos/{owner}/{repo}/pulls { title, body, head: feature/{feature_id}, base: {base_branch}, draft: true }
    Write handoff_pr_url into status.yaml
    Commit and push status.yaml to feature branch
```

`feature_branch_base_sha` is the merge-base of the feature branch and the base branch at first creation. The drift detector (`autonomous-feature-reviewer`) uses this SHA as its comparison baseline — "what was on main when this feature started." It must never be overwritten on restart.

Opening the draft PR at branch creation time gives stakeholders visibility into the feature branch throughout the entire implementation lifecycle, not just at handoff. The PR accumulates commits as tasks complete; at handoff it is converted from draft to ready-for-review (see Handoff Trigger below).

**Task PR target:** The orchestrator passes `base: feature/{feature_id}` when creating task PRs via the GitHub API. No change to executor agents — they open PRs as today; the orchestrator controls the PR target.

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

### Task PR Draft Lifecycle

Task PRs mirror task state — draft while the agent is working, ready-for-review only when a reviewer should act. The orchestrator owns all draft/ready transitions; the agent only opens the PR.

**Opening as draft (`pr-create` skill):**
The `/pr-create` skill adds `"draft": true` to the GitHub API PR creation payload. This is the only change to the agent side — all subsequent state transitions are orchestrator-driven.

**Promoting to ready (`dispatchExecutorResult`, `terminal_status: in_review`):**
When the orchestrator processes a result with `terminal_status: in_review` and a `pr_url` is present:
```
PATCH /repos/{owner}/{repo}/pulls/{pr_number}
body: { "draft": false }
```
Non-fatal: if the PATCH fails, emit a `task_pr_promote_failed` event and continue — the task still enters `in_review`.

**Demoting to draft (`dispatchReviewResult`, `change_requested` branch):**
When the reviewer posts REQUEST_CHANGES and the orchestrator mutates the task to `change_requested`:
```
PATCH /repos/{owner}/{repo}/pulls/{pr_number}
body: { "draft": true }
```
Non-fatal: if the PATCH fails, emit a `task_pr_demote_failed` event and continue — the task still enters `change_requested`.

**Owner/repo derivation:** Both dispatch functions receive `githubToken`, `repoOwner`, and `repoName` from the orchestrator configuration (already resolved at startup). The PR number is extracted from the stored `task.pr.url` via regex `/\/pull\/(\d+)$/`.

**Fix agent path:** The fix agent pushes commits to the existing branch; the PR stays draft. When it reports `terminal_status: in_review`, the same promotion path fires — PATCH `draft: false` again (idempotent if somehow already ready).

### Auto-Done Writer
When the quality gate passes:
1. Follows branch checkout + sync protocol on the management repo.
2. Writes `done` log entry to the task YAML (`actor: orchestrator`, real timestamp).
3. Runs auto-ready cascade: finds tasks whose `depends_on` are now all `done`, transitions them `todo → ready`, appends log entries.
4. Commits all changes and pushes to the feature branch.
5. After committing, checks if all tasks for the feature are now `done` — if so, triggers the Handoff Trigger.

### Handoff Trigger

Activates when the Auto-Done Writer transitions the **last** task to `done`.

1. Generate `handoffs/handoff.md` in the management repo (see structure below).
2. Convert the draft PR to ready-for-review: read `handoff_pr_url` from `status.yaml`, extract the PR number, call `PATCH /repos/{owner}/{repo}/pulls/{number}` with `{"draft": false}`. Safety net: if `handoff_pr_url` is null or the PR no longer exists, create a fresh non-draft PR and write the URL into `status.yaml`.
3. Transition `feature_status` to `in_handoff`, `current_stage` to `handoff`, and record `stages.handoff.pr_url`.
4. Commit and push management repo changes on the feature branch.
5. Notify operator via escalation channel.

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

### status.yaml additions

These fields are written by the orchestrator and read (never overwritten) by the `autonomous-feature-reviewer` drift daemon:

```yaml
feature_branch: feature/{feature_id}
feature_branch_base_sha: abc1234   # base branch tip at feature branch creation — never overwritten on restart
handoff_pr_url: null               # set by Handoff Trigger when feature PR is opened
drift_detected: false              # written by autonomous-feature-reviewer
drift_reason: null                 # written by autonomous-feature-reviewer
```

## Dependency Analysis

- Depends on existing task YAML schema — adds `change_requested` status and new log actions.
- Requires a new `review-pr` skill (`workflow/technical_skills/review-pr/`) with `references/review_criteria.md` carrying the full evaluation rubric.
- `handleDraftReviews` (`dispatch-draft-review.ts`) is **removed** by this feature.
- GitHub API (CI checks, PR reviews, PR creation for feature branch PR, branch compare) is used by the reviewer executor and Handoff Trigger. Uses existing `GITHUB_TOKEN`.
- Depends on Claude API for the reviewer executor (uses existing `ANTHROPIC_API_KEY`).
- Depends on Slack webhook for escalation (new config value: `SLACK_WEBHOOK_URL`).
- Depends on management repo SSH write access for feature branch creation, `status.yaml` updates, and handoff doc commit. Uses existing `SSH_KEY_PATH`.
- `REVIEWER_MAX_CYCLES` — optional env var controlling the review loop limit (default `3`). Must be documented in `.env.template`.
- `EXECUTOR_MAX_RETRIES` — optional env var controlling the max-turns retry limit (default `3`). Must be documented in `.env.template`.
- Impl executor agents are unchanged; fix agents reuse the same `kind=impl` result contract with a different briefing.
- `autonomous-feature-reviewer` is a downstream consumer — it activates on features this orchestrator moves to `in_handoff`. No build dependency; both can be built in parallel.

## Parallelization / Blocking Analysis

External dependencies: none blocking. `ANTHROPIC_API_KEY` and `GITHUB_TOKEN` are already assumed present; Slack webhook is optional until T6.

```
T1: Schema + CLAUDE.md + status.yaml fields — add `change_requested` status,
    new log actions (`reviewer_started`, `fix_started`, `retried`), new
    transitions, document status.yaml feature-branch fields
    (feature_branch, feature_branch_base_sha, handoff_pr_url,
    drift_detected, drift_reason), .env.template entries for
    REVIEWER_MAX_CYCLES / EXECUTOR_MAX_RETRIES / SLACK_WEBHOOK_URL.
    Remove handleDraftReviews from orchestrator.
  └── Can begin now — no blockers

T7: Orchestrator config — workspace.yaml orchestrator block with
    poll_interval, reviewer_max_cycles, executor_max_retries, escalation
  └── Can begin now — no blockers
  └── T1 and T7 run in parallel

  T2: Dispatch controller — poller routing table (ready→impl,
      change_requested→fix, in_review→reviewer), claim log actions,
      max-turns retry logic in dispatchExecutorResult, skeleton
      dispatchReviewResult handler, concurrency guard
      └── BLOCKED on T1 (change_requested status and log actions must be
          frozen before the routing table and claim entries are implemented)

  T8: Feature Branch Lifecycle Manager — pre-loop step: idempotent
      create/sync of feature/{feature_id}, records feature_branch_base_sha
      in status.yaml (never overwrites), sets task PR base to feature branch
      └── BLOCKED on T1 (status.yaml field schema must be settled first)
      └── Can run in parallel with T2 once T1 is done

    T3: review-pr skill — create workflow/technical_skills/review-pr/ with
        references/review_criteria.md, CI check logic, rubric evaluation,
        GitHub APPROVE / REQUEST_CHANGES posting, cycle limit via
        MAX_REVIEW_CYCLES env var, writes result.json
        └── BLOCKED on T1 (reviewer_started log action and result schema
            must be settled)
        └── Can run in parallel with T2 and T8 once T1 is done

    T4: Fix agent — briefing template for fix-agent executor, dispatch from
        change_requested status, reads REQUEST_CHANGES review URL from task
        log, addresses comments, pushes, returns terminal_status: in_review
        └── BLOCKED on T2 (fix agent dispatch hooks into T2's routing table
            and claim protocol)

    T5: Auto-done writer — on dispatchReviewResult terminal_status=passed:
        write done log entry + auto-ready cascade + push to feature branch;
        exposes all-tasks-done hook for T9 to attach the Handoff Trigger
        └── BLOCKED on T2 (dispatchReviewResult skeleton must exist)
        └── Can run in parallel with T4

    T6: Escalation handler — on dispatchReviewResult terminal_status=escalate:
        Slack webhook message + mutate task to blocked + blocked_reason
        └── BLOCKED on T2 (dispatchReviewResult skeleton must exist)
        └── Can run in parallel with T4 and T5

      T9: Handoff Trigger + document generation — fires after Auto-Done Writer
          detects all tasks done: generate handoff.md, open feature PR,
          write handoff_pr_url, transition feature_status to in_handoff
          └── BLOCKED on T5 (all-tasks-done hook must exist)
          └── BLOCKED on T8 (feature branch must exist to open the PR against)
```

---

## Appendix A — Post-implementation Gap Analysis

Discovered after T1–T9 merged by running the orchestrator end-to-end on this feature.

### Gap 1 — Self-review failure in reviewer agent

**Observed:** The bot GitHub account that opens implementation PRs (via `pr-create`) is the same account the reviewer agent uses. GitHub returns HTTP 422 when a user attempts to post a formal `APPROVE` or `REQUEST_CHANGES` review on their own PR. The `review-pr` skill uses a single `POST /pulls/{n}/reviews` call that bundles the comment body and the review event. On 422, both are lost — no comment lands on the PR, and the executor fails.

**Root cause:** The self-review restriction applies to `POST /repos/{owner}/{repo}/pulls/{n}/reviews`. It does not apply to `POST /repos/{owner}/{repo}/issues/{n}/comments`.

**Fix (T10):** Split the review post into two separate calls:

1. **Comment body** — `POST /repos/{owner}/{repo}/issues/{n}/comments`. Always succeeds regardless of PR authorship. Posts the full review narrative, findings, and recommendations as a regular comment.
2. **Review event** — `POST /repos/{owner}/{repo}/pulls/{n}/reviews` with `event: "APPROVE"` or `"REQUEST_CHANGES"`. Attempt after posting the comment. On HTTP 422, emit `reviewer_self_review_skipped` and continue without failing the executor.

The task YAML mutation (`passed` or `change_requested`) proceeds regardless of whether the formal review event was accepted by GitHub. The comment provides the human-readable record.

New event: `reviewer_self_review_skipped` (`task_id`, `feature_id`, `pr_number`).

### Gap 2 — Workspace PR status not written back after successful merge

**Observed:** In `handleMergedPrs`, after `mergeWorkspacePrViaApi` succeeds, the function emits `workspace_pr_merged` but does not write `task.workspace_pr.status = "merged"` back to the task YAML. The task YAML retains `workspace_pr.status: open`. On the next poll cycle, `handleWorkspacePrRecoveries` sees the open status, calls the GitHub API, receives a 404 or 422 (already merged), and produces noisy events. The same issue affects the fast path (task already `done` but workspace PR still open).

**Root cause:** The workspace PR merge (step 6 in `handleMergedPrs`) runs after the task YAML has already been committed and pushed (step 5). The merged status is never written back.

**Fix (T11):** After `mergeWorkspacePrViaApi` succeeds in both paths, write `task.workspace_pr.status = "merged"` to the task YAML, commit with message `chore(TN): record workspace PR merged`, and push to the task branch. On push failure, fetch + rebase + retry once; if still failing, emit `workspace_pr_status_write_failed` (non-fatal — the PR is already merged on GitHub; the stale `open` status will be retried next cycle).

### Gap 3 — Handoff trigger asymmetry + state invariant checker

**Observed:** Two code paths can mark a task `done`, but only one fires the handoff:

| Path | Marks task `done` | Calls `checkAllTasksDone` | Fires handoff |
|---|---|---|---|
| Reviewer agent (`kind=review`) → `dispatchReviewResult` | Yes | Yes | **Yes** |
| Impl PR merged on GitHub → `handleMergedPrs` | Yes | No | **No** |

When the last task reaches `done` via the pr-merge loop (impl PR merged without going through the reviewer agent), the handoff trigger never fires. Additionally, auto-ready cascade failures in `handleMergedPrs` (push rejected after rebase conflict) leave dependent tasks stuck in `todo` with no automatic recovery.

**Fix — part 1: Inline symmetry (T12)**

Add `checkAllTasksDone` + `fireHandoffTrigger` to `handleMergedPrs` immediately after the task YAML push succeeds, symmetric with `dispatchReviewResult`. The handoff fires regardless of which "done" path the last task takes.

**Fix — part 2: State invariant checker (T12)**

A lightweight checker that runs inside the existing poll cycle every N cycles (default 5, controlled by `STATE_INVARIANT_CHECK_INTERVAL`) as a safety net. Not a new loop — a single function called after `handleMergedPrs` on the same cycle. Scans all task YAMLs for two invariant violations:

1. **Stuck dependent** — task is `done` but a sibling task is `todo` with all its `depends_on` entries satisfied → apply `todo → ready`, append `ready` log entry.
2. **Stuck handoff** — all tasks are `done`/`cancelled` (at least one `done`), `feature_status` is not `in_handoff`, `handoff_pr_url` is null → re-invoke `fireHandoffTrigger`.

The checker is a recovery mechanism for failures in the primary path, not the primary path itself. Emits `state_invariant_violation` for each correction applied.

**Design rationale:** The system stays event-driven for the normal path. The invariant checker is a single scan function called at most once per 5 cycles inside the existing poll loop — not a new timer or process. The primary inline dispatch + handoff path handles the normal case; the checker is the fallback.
