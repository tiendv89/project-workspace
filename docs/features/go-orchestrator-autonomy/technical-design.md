# Technical Design

## Feature
- Feature ID: `go-orchestrator-autonomy`
- Title: Go Orchestrator — Autonomous Parity (reviewer cycle, handoff, error recovery, unblock)

> This feature is **executed by the TS orchestrator** (owner absent ⇒ `ts`) — the Go orchestrator is
> its *subject/output*, not its executor, because the Go orchestrator is still being built. Task state
> therefore lives in git (`tasks/T<n>.yaml`), not the DB.

## 1. Current state
`workflow-db` delivered the Go/Postgres orchestrator as a **human-merge slice**: guarded-`UPDATE`
atomic claim, broker dispatch (`owner='go'`), reap → `in_review`, dependency auto-ready, and
`in_review → done` via a GitHub PR-merge poll — but only when a **human** merges the impl PR. The Go
orchestrator has an in-memory `HandleStore` + reap loop, but **no reviewer cycle, no dispatch
reconciler, no conflict resolution, no handoff/finalize, no human-unblock surface, and no concurrency
throttle**. The TS orchestrator implements all of these (reviewer dispatch + verdict routing, fix
loop, dispatch reconciler, drift/conflict handling, handoff trigger + done-watcher, escalation). This
feature reimplements that behaviour against the DB — "same behaviour, not the same code".

Relevant boundaries: broker (Redis streams + registry), dispatcher (spawns executors, enforces
`DISPATCHER_MAX_CONCURRENT`, DLQ), executors + agent skills (`review-pr`, `respond-to-review`), and
the `workspace-github-adapter` (syncs git `status.yaml` → DB). Legacy `owner IS NULL` features remain
TS-driven and untouched.

## 2. Problem framing
**Change:** add the autonomous loops to the Go orchestrator — reviewer cluster, fix loop,
review-incomplete retry/escalate, conflict resolution (task + handoff PRs), feature lifecycle
(`in_implementation → in_handoff → done`) with handoff trigger + finalize, error/stuck recovery
(crash, spawn-DLQ, redis, max-turns), a concurrency throttle, and a human-unblock surface.

**Must remain stable:** the `workflow-db` write path (claim/dispatch/reap/auto-ready/PR-merge poll);
the broker/dispatcher/executor; the existing agent skills; the TS orchestrator and all `owner IS NULL`
features.

**Fixed assumptions:** guarded-`UPDATE` first-write-wins is the only mutation primitive (multi-instance
safe); the `owner` partition (`go` vs absent-ts) is authoritative; broker `handle`+`nonce` give
exactly-once spawn/completion; the **executor** already creates `feature/<id>` (`ensureImplFeatureBranch`);
conflict detection uses GitHub `mergeable` (the TS base-SHA **drift daemon is dropped**).

## 3. Options considered

**A. Git/GitHub ownership in the orchestrator.**
- *A1 — orchestrator does git only at handoff, via REST (chosen).* Orchestrator's only git-write is
  opening handoff PRs (refs/pulls/contents APIs); all task-level git stays with executors. ✅ no
  working tree, SSH, or checkout infra in the orchestrator; consistent with the execution-only model.
  ❌ conflict rebases must be delegated to agents.
- *A2 — full working-tree git in the orchestrator.* ✅ self-contained, closest to TS. ❌ large infra
  expansion (checkouts, SSH, disk, conflict handling) in a git-free service.
- *A3 — delegate all git (incl. PR creation) to agents.* ✅ orchestrator stays pure DB. ❌ async
  lifecycle events, new agent kind, weaker atomicity.

**B. Conflict detection.**
- *B1 — GitHub PR `mergeable` at poll time (chosen).* ✅ no base-SHA tracking, no drift daemon, no
  `feature_branch_base_sha`; reuses the existing poll. ❌ conflicts surface at PR/merge time, not
  proactively during dev (acceptable — see §4).
- *B2 — TS drift daemon (base-SHA compare + eager rebase).* ✅ early detection. ❌ base-SHA state,
  rebase churn, executor/rebase races; more machinery. **Rejected — not built.** No drift daemon, no
  `feature_branch_base_sha`, no `drift_detected`/`drift_reason`.

**C. In-flight count for the soft-claim throttle.**
- *C1 — derived DB count (chosen).* Count task/PR rows in dispatched states each cycle. ✅ no drift/leak;
  correct under crash/reconcile/multi-instance; no stored state. ❌ a `count(*)` per cycle (cheap, indexed).
- *C2 — maintained `+1/-1` counter.* ❌ leaks on crash (never decremented), double-counts on reconcile,
  needs multi-instance care. Rejected.
- *C3 — broker `registry-size`.* ✅ exact in-flight, matches dispatcher cap. ❌ broker coupling; may be
  global (ts+go) not owner-scoped. Rejected to avoid coupling.

**D. Dispatch metadata storage.**
- *D1 — dedicated `workspace_tasks` columns (chosen).* ✅ atomic per-column SET in the guarded UPDATE;
  atomic `reenqueue_attempts = reenqueue_attempts + 1`; no clobber. ❌ a few extra columns.
- *D2 — pack into the `execution` JSONB blob.* ❌ `GuardedTransition` writes JSONB wholesale → multiple
  writers (claim/reconciler/reap) clobber each other (lost `reenqueue_attempts` increment fails UNSAFE).
  Rejected.

**E. Reviewer verdict ingestion.**
- *E1 — broker completion / `result.json` via reap (chosen).* ✅ reuses the existing reap path; one
  completion mechanism. ❌ trust depends on a valid result (handled by `review_incomplete`).
- *E2 — GitHub review-state poll.* ✅ GitHub source of truth. ❌ a second polling subsystem; races.

**F. Rebase-cap failure on a `review_passed` (human-merge) task.**
- *F1 — do NOT block; keep `review_passed` + `conflict_state=conflicted` + Slack (chosen).* The human
  is already the merge actor, so a failed auto-rebase just means "human, resolve + merge." ✅ preserves
  the approval; no unblock dance. Blocking applies only to the auto-merge (`in_review`) path.
- *F2 — block + restore prior state via `blocked_from_status`.* ❌ strips the approval for no benefit.

**G. Feature-status DB writes.**
- *G1 — orchestrator writes `in_implementation`/`in_handoff`/`done`; adapter owner-scoped off those
  (chosen).* ✅ Go orchestrator becomes sole owner of go feature lifecycle in the DB; a definitive
  `handoff` idempotency marker. ❌ requires an adapter change.
- *G2 — rely purely on adapter sync from `status.yaml`.* ❌ `status.yaml` lags during execution →
  adapter clobbers the orchestrator's `handoff` state. Rejected.

## 4. Chosen design (by subsystem)

**Reviewer cluster.** Dispatch a reviewer (broker `review` kind) for `in_review` tasks; `in_review →
reviewing` is the guarded duplicate-dispatch claim. Verdict via **broker completion** (reap):
`passed → review_passed`; `change_requested`; no-valid-verdict → `review_incomplete` (retry ≤
`MAX_REVIEW_INCOMPLETES`=2, then `blocked`). The **reviewer agent performs the task-PR merge**
(best-effort REST squash, honouring `requires_human_review`); orchestrator observes `merged:true` via
the existing poll → `done`. Fix loop: `change_requested → in_progress` (guarded) → fix agent completes
`in_review` → re-review.

**Merged-PR-is-ground-truth (reviewing/merge race).** The reviewer auto-merges the PR *within its run*,
so the PR can be merged on GitHub while the task is still `reviewing` (verdict not yet reaped). Normally
the `passed` verdict reaps → `review_passed` → poll → `done`. But if the reviewer **merges then crashes
before the verdict is reaped**, the task would be stuck `reviewing` with a merged PR, and naive recovery
(`review_incomplete` / reconciler) would wrongly re-dispatch a reviewer on a merged PR. Rule: **an
observed merged impl PR is terminal truth** — the PR-merge poll transitions the task to `done` from any
of `in_review`/`reviewing`/`review_passed` (guarded). A late/lost reviewer verdict then no-ops against
the `done` row. Defensively, reviewer dispatch **and** the reconciler skip any task whose PR is already
merged, so they never re-review a merged PR. (Only the auto-merge path has this window; with
`requires_human_review:true` the reviewer stops at `review_passed` and never merges.)

**Terminal-state protection.** `done` and `cancelled` are terminal — no transition may leave them, so a
merged (`done`) task must never be regressed by a late/racing update. Ordinary guarded UPDATEs name a
specific FROM status and already no-op against a terminal row. **The one leak is the `*`-wildcard guard:**
`SetBlocked` currently guards `WHERE status='*'` (any status), so a late failure completion (DLQ
`"failed"`, reconciler-max, max-turns) — or any block — arriving for an already-`done` (or `cancelled`)
task would wrongly regress it to `blocked`. **Fix: `SetBlocked` and every `*`-guarded transition must
guard `WHERE status NOT IN ('done','cancelled')`;** and reap drops completions whose task is already
terminal. This composes with merged-is-ground-truth (reviewer merges → poll → `done`; a racing
failed/blocked completion then no-ops).

**Conflict resolution (replaces the TS drift daemon).** Detect via GitHub `mergeable`
(`CONFLICTING`→resolve; `UNKNOWN`→skip+recheck). Tracked by a **persisted** `conflict_state`
(`none/conflicted/resolving/resolved`); `resolving` is the guarded rebase-dispatch guard (TS's
in-memory `rebaseInFlight` is not multi-instance safe). Two paths by merge actor: **Path A** (auto-merge,
reviewer 409 at merge) → `change_requested` → fix agent rebases → `in_review` → re-review+re-merge;
**Path B** (human-merge, conflict on `review_passed`) → rebase, **stay `review_passed`**, human merges.
Rebase cap `MAX_REBASE_ATTEMPTS`=3: Path A → `blocked (rebase_failed)`; Path B / handoff-PR → stay +
`conflicted` + Slack.

**Feature-branch lifecycle — already solved.** The executor creates+pushes `feature/<id>`
(`ensureImplFeatureBranch`); the orchestrator never creates it and its only git-write is handoff PRs.

**Handoff + handoff-PR rebase loop.** Predicate: all tasks `done`/`cancelled`. On trigger: guarded
`feature_status='handoff'` (idempotency + multi-instance guard) + `UNIQUE(feature_id)` on `handoffs`;
create a `handoffs` row + one `handoff_prs` row per **distinct repo referenced by the feature's tasks**;
open draft feature→main PRs + the mgmt-repo status PR; missing feature branch in a touched repo → skip
+ Slack TODO. A **high-priority loop** rebases `CONFLICTING` handoff PRs before task dispatch (close
features fast); these count toward the soft-claim budget and are covered by the reconciler. Finalize:
all handoff PRs merged → merge mgmt PR → `done`. Adapter owner-scope fix so the adapter never clobbers
orchestrator-owned `in_implementation`/`in_handoff` (gate on **current DB value**; `cancelled`/`done`
still win).

**Error/stuck recovery.** Failure context on task columns (`blocked_reason` + `blocked_details`).
(a) crash → dispatch reconciler (`EXECUTION_DEADLINE_MS`=2h, re-enqueue **same handle+nonce** ≤
`DISPATCH_RECONCILE_MAX_RETRIES`=3, increment counter durably **before** enqueue, then `blocked`);
(b) spawn-DLQ → dispatcher posts synthetic `terminal_status:"failed"` after `DISPATCHER_MAX_DELIVERIES`=5
→ orchestrator adds a `"failed"` reap case → `blocked`; (c) redis enqueue failure → never roll back
(would double-spawn on ambiguous success); re-enqueue same handle; infra-level, no task block;
(d) max-turns → reset `in_progress → ready` ≤ `EXECUTOR_MAX_RETRIES`=3 then `blocked` (impl+fix; review
uses `review_incomplete`; rebase uses its own cap).

**Concurrency.** Do NOT port TS's in-memory `dockerInFlight`. Hard cap = dispatcher
`DISPATCHER_MAX_CONCURRENT` vs broker `registry-size`. Add a **soft claim-throttle**:
`headroom = MAX_INFLIGHT − inflight`, `inflight` **derived** (§ predicate below) — applied before every
dispatch kind against one shared budget. Soft by design (bounded multi-instance overshoot; dispatcher
is the hard cap).

**Human-unblock.** Backend unblock API → bff proxy (UI path) → workflow-mcp `unblock_task` tool → agent
`unblock-task` skill (mirrors the workflow-db create-tasks plumbing). Unblock **resumes** a blocked task
(abandoning it is the separate general `→ cancelled` operation, not an unblock). The resume state is
**derived deterministically from `blocked_from_status`** (recorded on every `→blocked`) — **no
caller-chosen target** — mapping each dispatched state to its re-claimable predecessor: `in_progress →
ready`; `reviewing`/`in_review` → `in_review` (the dispatched states can't be resumed directly — the
executor/handle is gone). Every blocked cause is unblockable, e.g. **review-incomplete-exceeded**
(→ `in_review`, re-dispatch reviewer) and **`rebase_failed`** on a task PR (→ `in_review`, after the
human resolves the conflict). UI itself out of scope.

**Unblock MUST reset the counter that caused the block**, else the task re-blocks immediately with zero
budget: review-incomplete-exceeded → `review_incomplete_count`=0; `rebase_failed` → `rebase_attempts`=0
**and** clear `conflict_state` (human resolved the conflict); max-turns cap → `max_turns_retry_count`=0.
Crash/spawn/agent blocks need no explicit reset (`reenqueue_attempts` is per-dispatch, reset on the next
dispatch).

### Task status FSM
| From | To | Trigger | Guard / actor |
|---|---|---|---|
| todo | ready | all `depends_on` done | auto-ready |
| ready | in_progress | impl claim | guarded `ready→in_progress` |
| change_requested | in_progress | fix claim | guarded |
| in_progress | in_review | impl/fix complete | reap |
| in_progress | ready | max-turns retry (`< EXECUTOR_MAX_RETRIES`) | reap (`max_turns`) |
| in_progress | blocked | reconciler-max / DLQ `failed` / agent block / max-turns cap | reconciler/reap |
| in_review | reviewing | reviewer dispatch | guarded `in_review→reviewing` |
| review_incomplete | reviewing | reviewer re-dispatch | guarded |
| reviewing | review_passed | APPROVE | reap |
| reviewing | change_requested | REQUEST_CHANGES or reviewer 409 (Path A) | reap |
| reviewing | review_incomplete | no valid verdict (`< MAX`) | reap |
| review_incomplete | blocked | no valid verdict (`>= MAX`) | reap |
| in_review / reviewing / review_passed | done | impl PR **observed merged** (ground truth) — covers the reviewer-auto-merged-then-crashed-before-verdict-reaped race | handleMergedPrs, guarded `WHERE status IN (in_review, reviewing, review_passed)` |
| blocked | ready / in_review | human unblock (cause-aware) | human (unblock API) |
| any **non-terminal** | cancelled | human | human, guarded `WHERE status NOT IN ('done','cancelled')` |

### conflict_state FSM (tasks AND handoff_prs)
`none → conflicted` (poll `mergeable=false`) → `resolving` (rebase dispatched, guarded) → `resolved`
(success). `resolving → conflicted` (retriable failure `< MAX_REBASE_ATTEMPTS`). Cap: task Path A →
`blocked`; task Path B (`review_passed`) / handoff_pr → stay + `conflicted` + Slack.
**INVARIANT:** `resolving` ⟺ a rebase executor is in-flight (every completion exits `resolving`).

### feature_status FSM (owner split)
`in_design → in_tdd → ready_for_implementation` (adapter, from status.yaml) → `in_implementation`
(orchestrator, first dispatch) → `in_handoff` (orchestrator, handoff) → `done` (orchestrator, finalize).
`any → cancelled`. Orchestrator OWNS `in_implementation`/`in_handoff`/`done-at-finalize`; adapter must
not clobber those.

### Per-task/PR counters + reset rules
| Column | Scope | Reset |
|---|---|---|
| dispatch_handle / dispatch_nonce / dispatched_at | per-dispatch | set on dispatch-in; clear on dispatch-out |
| reenqueue_attempts | per-dispatch | 0 on dispatch-in; clear on dispatch-out (NOT on enqueue-success) |
| max_turns_retry_count | per-work-episode | 0 on success exit `→in_review`; also 0 on unblock |
| review_incomplete_count | per-review | reset when review concludes; also 0 on unblock |
| rebase_attempts | per-conflict-episode | 0 on `conflict_state=resolved`; also 0 on unblock |
| blocked_from_status | — | set on `→blocked`; read on unblock |

### In-flight (soft-claim) predicate
`count(workspace_tasks WHERE status IN ('in_progress','reviewing') OR conflict_state='resolving')`
`+ count(handoff_prs WHERE conflict_state='resolving')` ≤ `MAX_INFLIGHT`.

### Cycle order (per poll)
feature-branch/handoff triggers → **handoff-PR conflict-rebase + finalize (HIGH prio)** → task dispatch
(claim/fix/reviewer/task-rebase) with leftover headroom → reap → dispatch reconciler.

## DB design (schema changes)

All migrations are owned by **workflow-backend** (Migration-ownership rule): a schema-changing task in
another repo commits goose artifact SQL under `db/testdata/` and spawns a downstream workflow-backend
migration task. All new columns are additive/nullable-or-defaulted → backward compatible.

### Altered table — `workspace_tasks` (ADD COLUMNS)
| Column | Type | Default | Purpose |
|---|---|---|---|
| `dispatch_handle` | text | null | current dispatch handle (broker idempotency key); persisted so the reconciler survives restart |
| `dispatch_nonce` | text | null | broker completion nonce (reused on reconciler re-enqueue) |
| `dispatched_at` | timestamptz | null | dispatch time; base for the reconciler `EXECUTION_DEADLINE_MS` check |
| `reenqueue_attempts` | int | `0` | reconciler re-enqueue count (per-dispatch) |
| `review_incomplete_count` | int | `0` | reviewer no-valid-verdict count (per-review) |
| `max_turns_retry_count` | int | `0` | max-turns reset count (per-work-episode) |
| `rebase_attempts` | int | `0` | rebase-failure count (per-conflict-episode) |
| `conflict_state` | text | `'none'` | `none` \| `conflicted` \| `resolving` \| `resolved` |
| `blocked_from_status` | text | null | status held at `→blocked` (cause-aware unblock target) |
| `blocked_details` | text | null | structured/free-text failure context set alongside `blocked_reason` (see §"Error/stuck recovery") |
| `dispatch_kind` | text | null | (optional) `impl`\|`fix`\|`review`\|`rebase` — lets the reconciler rebuild the right job |

> **Correction (post-implementation):** the original version of this table omitted `blocked_details`,
> even though the "Error/stuck recovery" prose above and T6's implementation both required it. Migration
> `00021_go_orchestrator_autonomy.sql` (T1) shipped without it, which broke every orchestrator poll
> query (`column blocked_details does not exist`). Fixed by a follow-up migration,
> `00022_workspace_tasks_add_blocked_details.sql`, in `workflow-backend`.

### New table — `handoffs` (one row per feature handoff)
| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK, `gen_random_uuid()` |
| `workspace_id` | uuid | not null |
| `feature_id` | uuid | not null; **`UNIQUE(feature_id)`** — one handoff per feature + the multi-instance trigger guard |
| `mgmt_pr_url` | text | null — the management-repo status PR |
| `status` | text | `open` \| `finalized` |
| `created_at` / `finalized_at` | timestamptz | `now()` / null |

### New table — `handoff_prs` (one row per impl-repo handoff PR)
| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `handoff_id` | uuid | not null, **FK → `handoffs(id)` ON DELETE CASCADE** |
| `repo` | text | `workspace.yaml` repo id |
| `pr_url` | text | null when skipped |
| `status` | text | `open` \| `merged` \| `skipped_no_branch` |
| `conflict_state` | text | `'none'` default — drives the handoff-PR rebase loop |
| `rebase_attempts` | int | `0` |
| `dispatch_handle` / `dispatch_nonce` / `dispatched_at` / `reenqueue_attempts` | (as tasks) | for the rebase dispatch + reconciler |
| `created_at` | timestamptz | `now()` |
- Constraint: **`UNIQUE(handoff_id, repo)`** (one handoff PR per repo per handoff).

### Indexes
The per-cycle **soft-claim in-flight count spans BOTH tables** —
`count(workspace_tasks … dispatched) + count(handoff_prs WHERE conflict_state='resolving')` — so both
halves want an index; likewise the reconciler scans both tables for stuck dispatches.
- **Reused (no change):** `workspace_tasks (workspace_id, owner, status)` — all status scans;
  `UNIQUE(workspace_id, feature_id, task_name)` prefix — handoff-completion predicate;
  `handoffs UNIQUE(feature_id)`.
- **ADD — partial index on `workspace_tasks` (needed):**
  `... (workspace_id) WHERE owner='go' AND (status IN ('in_progress','reviewing') OR conflict_state='resolving')`.
  Serves the tasks half of the per-cycle in-flight count (O(dispatched), not O(all go tasks — which grow
  unbounded)) and the reconciler's `dispatched_at < deadline` scan. Tiny (only in-flight rows).
- **ADD — partial index on `handoff_prs` (mirrors the above for the handoff half):**
  `... WHERE conflict_state='resolving'`. Serves the handoff-PR half of the same per-cycle count and the
  handoff-PR reconciler. Lower priority than the tasks index — `handoff_prs` grows slowly (bounded by
  handed-off features × repos), so a scan is cheap — but added for consistency of the per-cycle query.
- **ADD — `handoff_prs(handoff_id)`:** FK-join index for the finalize check (all PRs of a handoff merged?)
  and per-handoff PR listing (Postgres does not auto-index FK columns).
- **Not indexed:** the counter/handle columns (read as part of the row, never filtered on); the
  handoff-PR-rebase loop's `status='open'` scan (small table — a scan is cheap).

## API design (unblock task)

The unblock capability mirrors the workflow-db **create-tasks** plumbing across four layers. A human
(via UI) and an agent (via MCP) both hit the same backend endpoint.

### workflow-backend — endpoint
```
POST /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId/unblock
```
- **Auth:** org-scoped session (same mechanism as the create-tasks API); rejects tasks outside the caller's org.
- **Request body** (optional): `{ "note": "…" }`. **No `target`** — the resume state is derived
  server-side. `note` is stored on the activity event (audit: why/what the human did to fix the blocker).
- **Resume state (derived, not chosen)** from `blocked_from_status` — each dispatched state maps to its
  re-claimable predecessor: `in_progress → ready`; `reviewing`/`in_review` → `in_review`. Deterministic
  and coherent by construction (no override → no override-validation needed).
- **Validation:** task exists (else `404`) and is in the caller's org (else `403`); the guard enforces
  it is `blocked` (else `409`). The API does **not** verify the *external* blocker is resolved (image
  pushed, conflict fixed) — that's the human's assertion; a premature unblock self-corrects via the
  loops (re-review / re-detect conflict / re-block), it does not corrupt state.
- **Behaviour (single transaction):**
  1. Guarded `UPDATE workspace_tasks SET status=<derived> … WHERE workspace_id=$1 AND task_id=$3 AND status='blocked'`
     (first-write-wins; terminal-state protection is inherent — only a `blocked` row matches, so `409` if not).
  2. **Reset the causing counter** (per §4, keyed on `blocked_reason`): `review_incomplete_count`/
     `max_turns_retry_count`=0; `rebase_failed` → `rebase_attempts`=0 **and** clear `conflict_state`.
  3. Append a `workspace_activity_events` row (`action='unblocked'`, actor, `note`, from→to).
- **Responses:** `200 {task_id, from:"blocked", to:<derived>}`; `409` if the task is not `blocked`
  (already transitioned / lost the race); `404` unknown task; `403` wrong org.
- The Go orchestrator does not serve this — it just observes the resulting `ready`/`in_review` status
  via its existing loops (ready→claim; in_review→review/poll). No orchestrator endpoint.

### workflow-bff — proxy
Passthrough of the same path with identity injection (as the create-tasks proxy). No business logic.

### workflow-mcp — `unblock_task` tool
- **Input schema:** `{ workspace_id, feature (name or id), task (name or id), note? }` (no `target`) —
  resolves feature/task names to UUIDs (reuse the existing `get_feature` resolution), then calls the bff endpoint.
- **Auth:** session cookie (as `create_tasks`/`get_feature`).
- **Returns:** `{ ok, from, to }` (`to` is the server-derived resume state) or a structured failure
  (`{ ok:false, reason }`) for the `409`/`404`/`403` cases.

### agent-workflow — `unblock-task` skill
Wraps the MCP tool: reads the blocked task's `blocked_reason`/`blocked_from_status` (to inform the human
*why* it blocked), calls `unblock_task` with an optional `note`, and reports the server-derived outcome.
The resume state is decided server-side — the skill does not pick a target.

### UI (out of scope)
Not built here. When built, it calls the bff endpoint (an "unblock" action + optional note; the resume
state is derived server-side); the bff proxy + backend endpoint above are the contract it will consume.

## 5. Dependency analysis
- **Internal:** depends on `workflow-db` (claim primitive, broker owner-partition, PR-merge poll,
  auto-ready). Reuses agent skills `review-pr` (reviewer + merge) and `respond-to-review` (fix/rebase).
- **External / tooling:** GitHub REST (needs a **write-scope `GITHUB_TOKEN`** for the orchestrator, which
  previously only read); Redis broker + dispatcher (DLQ, registry-size).
- **Config:** new env — `MAX_INFLIGHT`, `MAX_REBASE_ATTEMPTS` (3); reused — `EXECUTION_DEADLINE_MS` (2h),
  `DISPATCH_RECONCILE_MAX_RETRIES` (3), `EXECUTOR_MAX_RETRIES` (3), `MAX_REVIEW_INCOMPLETES` (2),
  `DISPATCHER_MAX_CONCURRENT` (5), `DISPATCHER_MAX_DELIVERIES` (5).
- **Unresolved (blocking decisions):**
  - **D1** — whether `respond-to-review` can rebase a **feature branch → main** (it covers task-branch
    rebase); if not, feature→main conflicts are flag-for-human. Resolve before the handoff-PR rebase path.
  - **D2** — whether to refine the shared `CLAUDE.md` unblock rule to be cause-aware (`blocked_from_status`);
    surface to human before changing shared rules (feature proceeds with the cause-aware default regardless).
- Sibling `go-orchestrator-slack-notifications` consumes the `// TODO(slack)` seams left by this feature.

## 6. Parallelization / blocking analysis

> Anticipated decomposition — Phase 2 (`tech-lead` task breakdown) materializes these as
> `tasks/T<n>.yaml`. Repo ids are `workspace.yaml` ids; one repo per task (one-repo rule).

```
D1: Confirm respond-to-review can rebase feature→main (else flag-for-human) ── resolve before T6 handoff rebase
D2: Decide CLAUDE.md unblock-rule refinement (cause-aware)                   ── minor; resolve at/around T8

T1: workflow-backend — schema migration (task columns + handoffs/handoff_prs tables)
  └── Can begin now — no blockers
T2: workspace-github-adapter — owner-scope feature_status/current_stage/next_action for owner='go'
  └── Can begin now — no blockers
  └── T1 and T2 run in parallel
T13: workflow-orchestrator — README/AGENTS state-machine docs (from the approved design)
  └── Can begin now — authored from this design; refine as loops land
  │
  ├── T3: workflow-orchestrator — error/stuck recovery (reconciler, DLQ 'failed', redis, max-turns)
  ├── T4: workflow-orchestrator — reviewer cluster (dispatch/verdict/fix/review_incomplete)
  ├── T5: workflow-orchestrator — conflict resolution (conflict_state, rebase, cap, Path A/B)
  ├── T8: workflow-orchestrator — record blocked_from_status + unblock resume
  ├── T9: workflow-backend — unblock API endpoint
  │     └── BLOCKED on T1 (schema columns/tables must exist)
  │     └── T3, T4, T5, T8, T9 run in parallel
  │     └── T5's feature→main path also BLOCKED on D1
  │     │
  │     ├── T6: workflow-orchestrator — feature lifecycle (in_implementation, handoff trigger,
  │     │        handoff_prs, handoff-PR rebase loop, finalize)
  │     │     └── BLOCKED on T1 (handoffs/handoff_prs tables)
  │     │     └── BLOCKED on T5 (reuses conflict/rebase machinery for handoff-PR rebase)
  │     │     └── BLOCKED on T2 (adapter owner-scope so feature_status writes survive)
  │     │
  │     ├── T10: workflow-bff — unblock proxy
  │     ├── T11: workflow-mcp — unblock_task tool
  │     │     └── BLOCKED on T9 (unblock API must exist)
  │     │     └── T10 and T11 run in parallel
  │     │     │
  │     │     └── T12: workflow — unblock-task agent skill
  │     │           └── BLOCKED on T11 (mcp unblock_task tool)
  │     │
  │     └── T7: workflow-orchestrator — soft-claim throttle + cycle ordering (handoff-PR high prio)
  │           └── BLOCKED on T3, T4, T6 (integrates dispatch/reviewer/handoff loops into the cycle)
  │           │
  │           └── T14: workflow-orchestrator — E2E autonomous-run test (parallel with a legacy TS feature)
  │                 └── BLOCKED on T3, T4, T5, T6, T7, T8 (full autonomous path must exist)
```

Wave summary: **Wave 1** = T1, T2, T13 (no blockers). **Wave 2** = T3, T4, T5, T8, T9 (need schema).
**Wave 3** = T6, T7, T10, T11 (need Wave-2 pieces). **Wave 4** = T12, T14 (integration + skill).

## 7. Repository impact
| Repo (`workspace.yaml` id) | Why |
|---|---|
| `workflow-orchestrator` | All new orchestrator loops (reviewer, error-recovery, conflict, handoff + handoff-PR rebase, soft-claim, unblock-resume) + README/AGENTS state-machine docs. |
| `workflow-backend` | Migrations (task columns + `handoffs`/`handoff_prs`) and the unblock API endpoint. |
| `workspace-github-adapter` | Owner-scope `feature_status`/`current_stage`/`next_action` off `owner='go'`. |
| `workflow-bff` | Proxy the unblock endpoint with identity injection (UI path; UI out of scope). |
| `workflow-mcp` | Add the `unblock_task` tool. |
| `workflow` | New `unblock-task` agent skill wrapping the mcp tool (agent-workflow skills repo). Reused skills `review-pr`/`respond-to-review` unchanged. |

## 8. Validation and release impact
- **Testing:** unit — guarded transitions (each FSM edge), dispatch reconciler (same-handle/nonce
  re-enqueue, retry-cap, block), reap `"failed"` DLQ path, max-turns reset, conflict_state FSM +
  rebase-cap paths, derived in-flight predicate, adapter owner-scope CASE. Integration — **E2E
  autonomous run**: a go feature from `ready` → feature-level `done` (reviewer APPROVE → merge →
  handoff → finalize) **in parallel with a legacy `owner IS NULL` TS feature**, asserting the
  single-owner invariant and no cross-interference. Unblock chain end-to-end (API → mcp → skill).
- **Migration/config:** additive `workflow-backend` migrations (new columns default-null; new tables);
  new env vars (`MAX_INFLIGHT`, `MAX_REBASE_ATTEMPTS`); orchestrator needs a write-scope `GITHUB_TOKEN`.
- **Rollout ordering:** the adapter owner-scope change (T2) must deploy **together with or before** the
  orchestrator's `feature_status` writes (T6), else the adapter clobbers `in_implementation`/`in_handoff`.
- **Backward compatibility:** fully preserves the `owner` partition — legacy TS/`owner IS NULL` features
  are untouched; this feature is itself ts-owned and runs on the existing TS orchestrator.
- **Deployment/handoff:** standard docs PR → main; the `go-orchestrator-slack-notifications` feature
  later fills the `// TODO(slack)` seams. No data backfill required.
