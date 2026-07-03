# Tasks — `go-orchestrator-ui-integration`

> Feature status: `in_tdd` — technical design approved 2026-07-03. Task stage: **draft** — awaiting
> human approval.
>
> Narrative (description + required skills + subtasks) lives here; machine-readable state (status,
> deps, branch, log, PR) lives per-task in `tasks/T<n>.yaml`. Agents mutate only the YAMLs.
>
> This is a `ts`-tracked feature; the functionality it builds is for the `go` flow. See
> `technical-design.md` for the §-references cited below.

## Index

| ID | Wave | Title | Repo | Depends on |
|----|------|-------|------|------------|
| T1 | 1 | Thread `user_id` + `org_id` into tool execution context | hermes-agent | — |
| T2 | 1 | `write_tasks`: go branch stops at `tasks.md` (remove DB insert) | hermes-agent | — |
| T3 | 1 | `CreateTasks` server-side guard + structured reason codes | workflow-backend | — |
| T4 | 2 | workflow-backend service client (bulk create, service-to-service) | hermes-agent | T1 |
| T5 | 3 | Tasks-stage approve orchestration — resumable a→b→c→d (incl. ensure-docs-on-base + PR merge) | hermes-agent | T2, T3, T4 |
| T6 | 4 | Backup `/create-tasks` (hermes-internal, step-d only) + guard-error relay | hermes-agent | T5 |
| T7 | 5 | End-to-end verification (approve pipeline + backup path) | hermes-agent | T5, T6 |

**External dependency D1** (not a task): ops must provision `WORKFLOW_BACKEND_URL` and the shared
service token (`WORKFLOW_BACKEND_SERVICE_TOKEN`, accepted by `RequireBFFIdentity`) in the hermes
deployment. Code and unit tests proceed with placeholders; the live approve/create-tasks runtime is
blocked on D1. Also verify the existing `GITHUB_TOKEN` scope permits PR merge on the management repo.

---

## T1 — Thread `user_id` + `org_id` into tool execution context

### Description
Prerequisite for any hermes → workflow-backend call (§4.2). Today `identity.py` extracts
`Identity{user_id, org_id}` from `X-User-Id`/`X-Org-Id`, but `chat.py` forwards only `user_id` and
`plugins/context.py` stores just `(workspace_id, feature_id)` per session — so no tool `handle()` can
read the caller's identity. Thread both `user_id` and `org_id` through `chat.py` →
`agent_dispatch.py` → `plugins/context.py`, and expose them to tools. Additive and backward-compatible:
absent identity resolves to empty strings, exactly as today.

### Required skills
- python-best-practices

### Subtasks
- [ ] `chat.py`: forward `org_id` (currently dropped) alongside `user_id` into `_run_agent_turn_async`.
- [ ] `agent_dispatch.py`: pass `user_id` + `org_id` into `context.set_context(...)`.
- [ ] `plugins/context.py`: extend the per-session record and thread-local to carry `user_id`/`org_id`;
      add `get_user_id()` / `get_org_id()` getters mirroring `get_workspace_id()`/`get_feature_id()`.
- [ ] Unit test: identity set on a turn is readable via the new getters; absent identity → empty strings.

## T2 — `write_tasks`: go branch stops at `tasks.md` (remove DB insert)

### Description
Make the breakdown turn review-only for go features (§4.1). Remove the `owner == "go"`
`_insert_tasks_to_db(...)` block (`tasks_write.py:427-436`) so the go branch commits a comprehensive
`tasks.md` and returns — like the ts branch minus per-task YAMLs — with no DB write during breakdown.
**Sequencing:** must ship together with or after T5; never before (otherwise go breakdown stops writing
tasks while nothing yet creates them at approve — see §8).

### Required skills
- python-best-practices

### Subtasks
- [ ] Delete the `owner == "go"` `_insert_tasks_to_db(...)` block (`tasks_write.py:427-436`).
- [ ] Delete `_insert_tasks_to_db()` and now-unused `plugins/db.py` insert helpers / `psycopg`
      task-write imports if nothing else references them.
- [ ] Update the tool return payload/message: `db_tasks_inserted` (`:445`) and the
      `"Task state stored in DB."` message (`:448`) must reflect that go tasks are created later, at
      tasks-stage approval (or via backup `/create-tasks`) — not here.
- [ ] Unit test: go `write_tasks` commits `tasks.md`, performs **no** DB write, writes no `tasks/` YAMLs.
- [ ] Regression: ts `write_tasks` behavior unchanged (tasks.md + per-task YAMLs).

## T3 — `CreateTasks` server-side guard + structured reason codes

### Description
Add an additive guard to `CreateTasks` (`internal/service/task_create.go`) so every caller — hermes
approve path, hermes backup skill, `workflow-mcp`, CLI — is uniformly protected (§4.7). Reject with a
machine-readable reason when the feature is not in the tasks-approved state
(`feature_not_tasks_approved`) or when tasks already exist (`tasks_already_exist`, idempotency). The
DB-state check is sufficient because approve merges the docs PR (b) before updating DB stage (c), so a
tasks-approved feature already implies the merge. Success path and payload shape unchanged.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Resolve the exact tasks-approved predicate from the feature record (`feature_status`
      `ready_for_implementation` per the tasks-stage FSM; confirm field in code).
- [ ] Reject non-approved with `feature_not_tasks_approved`; reject when tasks already exist with
      `tasks_already_exist`. Return distinct, machine-readable reason codes (stable HTTP status).
- [ ] Go tests: reject-not-approved; reject-tasks-exist; success unchanged.
- [ ] Document the reason codes (contract for the hermes error relay in T5/T6).

## T4 — workflow-backend service client (bulk create, service-to-service)

### Description
New `src/services/workflow_backend_client.py` (§4.3), modeled on `user_service_client.py` (raw
`aiohttp` + Bearer). POST to
`{WORKFLOW_BACKEND_URL}/api/workspaces/{workspace_id}/features/{feature_id}/tasks` with
`Authorization: Bearer {WORKFLOW_BACKEND_SERVICE_TOKEN}`, `X-User-Id`, `X-Org-Id`, and
`X-Accessible-Org-Ids: {org_id}` sourced from the T1-threaded identity. Bulk, all-or-nothing; surface
the backend's error (incl. T3 reason codes) to callers. This is the shared step-d building block reused
by both T5 (approve) and T6 (backup).

### Required skills
- python-best-practices

### Subtasks
- [ ] Client module with header construction from threaded identity (T1 getters).
- [ ] Build the bulk payload from the approved `tasks.md` index table.
- [ ] Surface non-2xx responses with the backend reason code intact (for T5/T6 relay).
- [ ] Unit tests: header/payload construction; error surfacing (mock 4xx with reason code).

## T5 — Tasks-stage approve orchestration — resumable a→b→c→d

### Description
Extend `approve_feature.handle()` with a tasks-stage branch running a→b→c→d, fail-fast and
**resumable** — each step self-detects "already done" and skips, so re-running approve continues from
the failed step (§4.5). This task also owns **step b's ensure-docs-on-base + docs-PR merge** logic
(§4.4) — folded in here because the approve flow is its only caller.

- **a. promote (git):** existing `_commit_files` of `status.yaml`; skip if the branch already shows the
  tasks stage approved.
- **b. ensure docs on base:** keyed off **content, not PR existence** — read `status.yaml` via the
  GitHub Contents API (the `approve.py:151-162` pattern, no clone). If the base branch already contains
  the approved docs → skip. Else find open PRs `head=<feature branch>`, `base=<base branch>`: exactly
  one → merge; 0 (and not on base) → post "no docs PR / not on base — open a PR and re-run" to chat and
  halt; >1 → post "multiple PRs match" and halt. Branch names resolve from `status.yaml`
  (`feature_branch` else `feature/<feature_id>`) and `workspace.yaml` `repos[].base_branch` — never
  hardcode `main`.
- **c. DB status:** existing `update_feature_stage(...)` (`db.py:99`); idempotent set.
- **d. create tasks:** the T4 client; T3's `tasks_already_exist` makes a repeat a safe no-op. Relay
  T3 reason codes to chat on error.

On hard failure, return a message naming the failed step and instructing the user to re-run approve.
Earlier stages (`product_spec`, `technical_design`) unchanged.

### Required skills
- python-best-practices

### Subtasks
- [ ] Tasks-stage branch in `approve_feature.handle()`; earlier-stage behavior untouched.
- [ ] Step b: Contents-API `status.yaml` reader
      (`GET .../contents/docs/features/<fid>/status.yaml?ref=<branch>`, base64-decode, parse); skip if
      already on base; else merge single open PR / halt+notify on 0 (not-on-base) or >1.
- [ ] Wire a (skip-if-approved) → b → c (idempotent) → d (T4 client), fail-fast and resumable.
- [ ] On failure: return a clear message naming the failed step + "re-run approve" guidance; relay T3
      reason codes from step d.
- [ ] Unit/integration test: full happy path; resume after simulated failure at each of a/b/c/d;
      step-b cases (already-on-base skip, single-PR merge, zero-PR halt, multi-PR halt).

## T6 — Backup `/create-tasks` (hermes-internal, step-d only) + guard-error relay

### Description
A hermes-internal command (its own version based on the agent-workflow `create-tasks` skill, §4.6) that
does **only** step d — create tasks — never a/b/c. It **reuses T5's step-d create logic** (the T4-client
call + T3 reason-code relay), so it depends on T5. It relays guard errors to chat with next steps
(`feature_not_tasks_approved` → "re-run the approve command to complete a→b→c, then retry";
`tasks_already_exist` → "tasks already exist — nothing to do") and never merges the PR.

**Do not port the skill's "Step 1 — Resolve the feature" step.** That standalone skill has to identify
which feature it's operating on; in the hermes chat session the feature is already known — source
`feature_id` from `plugins/context.get_feature_id()`. Only a mechanical slug→UUID lookup remains *if*
the create API requires the UUID.

### Required skills
- python-best-practices

### Subtasks
- [ ] hermes-internal `/create-tasks` skill/tool invoking the shared step-d create logic from T5,
      sourcing `feature_id` from `plugins/context.get_feature_id()` — **not** the skill's Step-1 flow.
- [ ] Only if the create API needs a UUID: resolve slug→UUID mechanically (no interactive discovery).
- [ ] Map T3 reason codes → clear chat guidance; point a/b/c gaps back at the approve command.
- [ ] Unit tests: guard-reject → notification (no creation); success path; tasks-exist → safe no-op.

## T7 — End-to-end verification (approve pipeline + backup path)

### Description
Exercise the whole flow end to end (§8) against a test backend with a placeholder token: breakdown
produces `tasks.md` only (no DB write), tasks-stage approve runs a→b→c→d and creates tasks via the API,
re-run after a mid-way failure resumes correctly, and the backup `/create-tasks` behaves per its reason
codes (early guard reject → notification, no creation; after approve state → success; tasks-exist →
no-op).

### Required skills
- python-best-practices

### Subtasks
- [ ] E2E: create → spec/design approve → breakdown (tasks.md only) → tasks approve → tasks in DB via API.
- [ ] E2E: resumable approve — inject a failure at b and at d; re-run completes without duplication.
- [ ] E2E: backup `/create-tasks` — guard reject notification; success; tasks-exist no-op.
- [ ] Confirm ts flow and earlier-stage approvals are unaffected (regression).
