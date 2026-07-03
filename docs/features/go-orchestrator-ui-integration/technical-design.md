# Technical Design

## Feature
- Feature ID: `go-orchestrator-ui-integration`
- Title: Go orchestrator — Hermes tasks-stage approve pipeline (merge docs PR + create tasks via API)
- Tracked with: `ts` flow (this feature's own task state lives in `tasks/T<n>.yaml`). The functionality
  it builds is entirely for the `go` flow.

> RAG / GitNexus pre-flight: the `mcp__rag-server__*` and `mcp__gitnexus__*` tools are not available in
> this session. Per the graceful-degradation clause, this design is grounded in direct code inspection
> of `hermes-agent`, `workflow-backend`, `workflow-bff`, and `workspace-github-adapter` (file:line
> references throughout) plus the approved product spec.

---

## 1. Current state

### hermes-agent (`hermes-workflow-gateway`, Python/FastAPI)
The chat gateway behind `digital-factory-ui`. Its LLM tools live in `plugins/tools/`. Two matter here:

- **`plugins/tools/tasks_write.py`** (`write_tasks`): builds a `files` dict that *always* contains
  `docs/features/<dir>/tasks.md` (`tasks_write.py:407-410`). For `owner != "go"` it additionally adds
  per-task `tasks/T<n>.yaml` files; then `_commit_files(...)` commits via the GitHub Git Data API
  (`tasks_write.py:422`). For `owner == "go"` it *additionally* calls `_insert_tasks_to_db(wid, fid,
  tasks)` (`tasks_write.py:428-436`), writing task rows straight into `workflow-backend`'s Postgres via
  `plugins/db.py` (`WORKFLOW_DATABASE_URL`, `psycopg`). This DB write happens in the breakdown turn —
  before human tasks-stage approval, before any docs-PR merge, bypassing the validating API.
- **`plugins/tools/approve.py`** (`approve_feature`): already does two of the four actions the target
  flow needs. It commits `status.yaml` to the feature branch via `_commit_files` (`approve.py:240-241`)
  **and** writes the feature stage to the DB via `update_feature_stage(...)` (`approve.py:519`,
  `db.py:99`). It does **not** merge the docs PR and does **not** create tasks.

Supporting facts:
- **Identity** (`src/api/identity.py`): `Identity{user_id, org_id}` is extracted from `X-User-Id`/
  `X-Org-Id` headers (gated by `GATEWAY_SERVICE_TOKEN`). But `chat.py` forwards only `user_id` onward;
  `org_id` is dropped before `agent_dispatch.py`. `plugins/context.py` stores only a
  `(workspace_id, feature_id)` tuple per session (`context.py:31,36-45`) — no `user_id`/`org_id`. So no
  tool `handle()` can see the caller's identity today.
- **Outbound HTTP precedent**: `src/services/user_service_client.py` — raw `aiohttp` + `Authorization:
  Bearer <token>`. This is the established pattern for hermes → another backend.
- **GitHub precedent**: `tasks_write.py::_commit_files` uses the GitHub Git Data API with `GITHUB_TOKEN`
  (commits only; no PR-merge helper exists yet).
- **MCP client**: `plugins/mcp_client.py` (`call_mcp_tool` over SSE) is used only for read tools
  (GitNexus, RAG).

### workflow-backend (Go/gin)
- Tasks API: `POST /api/workspaces/:workspaceId/features/:featureId/tasks` →
  `internal/handler/workspace.go:67` → `h.CreateTasks` → `internal/service/task_create.go:24`. Bulk,
  all-or-nothing, restricted to `owner: go` features.
- Auth: `RequireBFFIdentity` (`internal/authmw/bff_identity.go:24`) — validates `Authorization: Bearer
  <serviceToken>` against a **shared service token**, then reads identity from `X-User-Id` / `X-Org-Id`
  / `X-Accessible-Org-Ids` headers and authorizes against `AccessibleOrgIDs`.
- No stage-transition/approve endpoint exists (confirmed absent).

### workflow-bff (Go/gin)
A generic reverse proxy (`NoRoute → Proxy`). Every proxied route requires a live browser `session_id`
cookie; it **strips inbound `Authorization`/`Cookie`** and injects its own `Bearer <internalToken>` +
`X-User-Id`/`X-Org-Id`/`X-Accessible-Org-Ids` from the resolved session. There is **no
service-to-service ingress path** — a backend caller with its own bearer token cannot authenticate
through the BFF.

### workspace-github-adapter
Periodically scans `status.yaml`/task YAMLs from GitHub and upserts `workflow_features.current_stage`/
`feature_status` into the DB. This is the existing git→DB feature-status sync.

---

## 2. Problem framing

**What must change:** move `go` task creation off the direct-DB shortcut and onto the validating API,
and make it happen only at the human-gated tasks-stage approval — as part of a single command that
promotes the feature, merges the docs PR, updates DB status, and creates the tasks. Add a
precondition-checked backup command for partial-failure recovery.

**What must remain stable:**
- The `ts` flow (`write_tasks` for non-go, per-task YAMLs, existing approvals) is untouched.
- Earlier-stage (`product_spec`, `technical_design`) approvals keep promote-only behavior.
- `approve.py`'s existing git-commit + `update_feature_stage` DB write stay as-is (steps a + c).
- The `workflow-backend` tasks API and `RequireBFFIdentity` contract are unchanged in shape.

**Fixed assumptions:**
- hermes is a trusted internal service (it already receives injected identity headers from the BFF).
- One docs PR (feature branch → base) accumulates spec + design + tasks and is merged at the tasks
  stage.
- `workflow-bff` cannot be used by hermes for service-to-service calls (established above).

---

## 3. Options considered

### Q1 — How does hermes authenticate to `workflow-backend`'s tasks API?

**Option A — Reuse the shared service token; hermes sets identity headers itself.** hermes calls
`workflow-backend` directly (no BFF) with `Authorization: Bearer <shared service token>` and sets
`X-User-Id`/`X-Org-Id`/`X-Accessible-Org-Ids` from the threaded caller identity.
- Pros: no `workflow-backend` code change (`RequireBFFIdentity` already accepts that token); mirrors the
  `user_service_client.py` precedent; smallest surface.
- Cons: hermes can assert any identity (same power the BFF already holds); the shared token now lives in
  a second service.
- Impact: hermes config (token + base URL); no backend change.

**Option B — Dedicated hermes credential.** Provision a distinct token/principal for hermes,
`workflow-backend` validates it separately.
- Pros: independent rotation/audit of hermes access.
- Cons: `workflow-backend` middleware change to accept multiple tokens; more moving parts.
- Impact: backend + hermes + ops.

**Option C — Route through the BFF.** Rejected outright: the BFF has no service-to-service path and
strips inbound auth (§1).

### Q2 — How does hermes locate the docs PR to merge?

**Option A (chosen) — Discover by head branch via GitHub API; notify chat on anything ambiguous.** List
open PRs with `head=<feature branch>`, `base=<base branch>`. Exactly one match → merge it. **0 matches
or >1 matches → do not auto-open and do not guess: post a clear message to chat describing the issue
(no PR found / multiple PRs) and halt the approve for the human to check manually.**
- Pros: no new state to persist; robust to who opened the PR; hermes already uses the GitHub API; never
  silently opens or merges the wrong thing.
- Cons: the 0/>1 cases require a human step (acceptable — these are genuinely ambiguous).

**Option B — Persist the PR number in `status.yaml`.** Store it when the docs PR is opened; read it at
merge time.
- Pros: unambiguous.
- Cons: requires a reliable writer at PR-open time (not currently guaranteed); adds a field to maintain;
  stale/missing values still force a fallback to discovery.

### Q3 — Ordering & failure handling across the four approve actions (a promote, b merge, c DB status,
d create tasks)

**Option A (chosen) — a → b → c → d, fail-fast, and the approve command itself is resumable.** Each
step is idempotent and self-detects "already done" and skips it. On any failure, approve stops and
returns a precise failure message that **guides the user to re-run the approve command**; the re-run
walks a→b→c→d again, skipping the steps that already completed and continuing from the failed one.
Recovery is the approve command's job — **not** the backup command's. The backup `/create-tasks` does
**only** step d (create tasks) and never attempts a/b/c.

**Option B — Best-effort, continue on error.** Rejected: risks creating tasks against an unmerged/
unsynced feature and hides partial state.

### Q4 — Where does the precondition live, and where does the backup `/create-tasks` live?

**Option A — Client-side precondition in the skill.** Each caller (skill) re-derives "approved + merged"
from git before calling the API.
- Pros: no backend change.
- Cons: precondition duplicated per caller; the `workflow-mcp` wrapper and any other caller can bypass
  it; the "merged to main" git check is awkward for every client to perform.

**Option B (chosen) — Server-side guard in `workflow-backend`, hermes relays the error.** `CreateTasks`
rejects with a structured error unless the feature is in the tasks-approved state, and also rejects if
tasks already exist for the feature (idempotency). Every caller — the approve orchestration, the backup
command, `workflow-mcp`, anything — is guarded uniformly. hermes catches the structured error and tells
the user the issue and the next step (e.g. "approve the tasks stage / merge the docs PR, then retry").
- Why the DB-state check is sufficient: the approve orchestration merges the docs PR (b) **before**
  updating the DB stage (c), so in the normal flow a feature reaching the tasks-approved DB state
  implies the merge already happened. The backend therefore does not need to inspect git — checking its
  own feature state is a correct proxy.
- The backup `/create-tasks` is a **hermes-internal skill/tool**, its own version based on the
  agent-workflow `create-tasks` skill, so the user can trigger recovery from chat. It calls the same
  API; the backend guard enforces preconditions; hermes relays any guard error to chat.
- Pros: single enforcement point; correct for all callers; clean chat-facing error handling.
- Cons: a `workflow-backend` code change (the guard) — small and additive.

---

## 4. Chosen design

**Q1 → Option A** (reuse shared service token; hermes sets identity headers). **Q2 → Option A**
(discover-by-branch; notify chat and halt on 0/>1 matches — never auto-open or guess). **Q3 → Option A**
(a→b→c→d, fail-fast; **the approve command is resumable** — re-run skips completed steps; the backup
`/create-tasks` does only step d). **Q4 → Option B** (server-side guard in `workflow-backend`; hermes
relays the error; the backup `/create-tasks` is a hermes-internal skill based on the agent-workflow one).

### 4.1 Breakdown turn (`write_tasks`) — go stops at `tasks.md`
`write_tasks` **is** the tech-lead Phase 2 breakdown tool, and today it creates the go tasks in the DB
*during breakdown* — before any human tasks-stage approval or docs-PR merge. This is the core logic to
remove. Confirmed in source:

```python
# tasks_write.py:427-436  — runs in the breakdown turn, owner == "go"
if owner == "go":
    try:
        _insert_tasks_to_db(wid, fid, tasks)
    except Exception as exc:
        ...
        return {"ok": False, "error": f"tasks.md committed ... but DB insert failed: {exc}"}
```

Changes:
- Delete the `owner == "go"` `_insert_tasks_to_db(...)` block (`tasks_write.py:427-436`). After it, the
  go branch behaves like the ts branch minus the per-task YAMLs: commit a full, comprehensive
  `tasks.md` and return. No DB write during breakdown.
- Delete `_insert_tasks_to_db()` itself if nothing else references it (and drop now-unused
  `plugins/db.py` insert helpers / `psycopg` task-write imports it pulled in).
- Update the tool's return payload and success message so it no longer claims DB insertion: the
  `db_tasks_inserted` field (`tasks_write.py:445`) and the `"Task state stored in DB."` message
  (`tasks_write.py:448`) must change to reflect that go tasks are now created later, at tasks-stage
  approval (or via the backup `/create-tasks`), not here.

This is the change that makes breakdown a review-only step: `tech-lead` produces `tasks.md` for the
human, and nothing lands in the DB until the human approves.

### 4.2 Identity threading (prerequisite)
Carry the caller's `user_id` **and** `org_id` from `identity.py` → `chat.py` → `agent_dispatch.py` →
`plugins/context.py` → tool `handle()`:
- `chat.py`: forward `org_id` (currently dropped) alongside `user_id` into `_run_agent_turn_async`.
- `agent_dispatch.py`: pass both into `context.set_context(...)`.
- `plugins/context.py`: extend the per-session record and thread-local to hold `user_id`/`org_id`; add
  `get_user_id()` / `get_org_id()` getters (mirroring `get_workspace_id()`/`get_feature_id()`).
- Tools read identity via these getters. Backward-compatible: absent identity ⇒ empty strings, same as
  today.

### 4.3 workflow-backend service client (in hermes)
New `src/services/workflow_backend_client.py`, modeled on `user_service_client.py`: `aiohttp` POST to
`{WORKFLOW_BACKEND_URL}/api/workspaces/{workspace_id}/features/{feature_id}/tasks` with headers
`Authorization: Bearer {WORKFLOW_BACKEND_SERVICE_TOKEN}`, `X-User-Id`, `X-Org-Id`, and
`X-Accessible-Org-Ids: {org_id}` (single-org action). Body is the bulk task payload derived from the
approved `tasks.md` index table. All-or-nothing; on non-2xx it raises with the backend's error surfaced.

### 4.4 Ensure-docs-on-base capability (in hermes)
The goal of step b is **"the approved docs are on the base branch,"** not "a PR object exists." So the
decision is driven by base-branch content first; merging an open PR is only the mechanism used when the
content isn't there yet. Extend hermes' GitHub API usage (alongside `_commit_files`) with a helper that,
for the management repo:

1. **Is the merge effectively already done?** Check whether the base branch already contains the
   feature's approved docs — concretely, the base-branch `status.yaml` already shows the tasks stage
   approved (equivalently, the feature branch is already merged into base). **If yes → skip step b and
   continue.** This covers the merged-PR / squash-merge / direct-merge cases uniformly: hermes never
   asks the user to reopen a PR that is already merged, because it keys off content, not the PR object.
2. Otherwise the docs are **not** yet on base and a merge is needed. Find open PRs with
   `head=<docs feature branch>`, `base=<base branch>`:
   - **exactly one open match → merge it**;
   - **0 open matches (and base does not yet contain the docs) → post a clear "no docs PR found for
     `<branch>` and its changes are not on `<base>` — open a PR and re-run" message to chat**, and halt
     (do not auto-open);
   - **>1 open matches → post a "multiple PRs match `<branch>`: #a, #b" message to chat** and halt for
     manual resolution.

The feature/branch names resolve from `status.yaml` (`feature_branch` if present, else
`feature/<feature_id>`) and `workspace.yaml` `repos[].base_branch` for the management repo — never
hardcode `main`.

**How status checks read git (no clone).** hermes is a stateless service; it never clones the repo. All
`status.yaml` reads use the GitHub REST **Contents API** — the exact pattern `approve.py:151-162`
already uses (`GET /repos/{owner}/{repo}/contents/docs/features/<feature_id>/status.yaml?ref=<branch>`,
base64-decode, parse YAML, read `stages.tasks.review_status`). The `?ref=` selects the branch:
`ref=<base_branch>` for the step-b "already on base?" check, `ref=<feature_branch>` for the step-a
skip check. `status.yaml` is well under the Contents API's ~1 MB limit. Do not introduce `git clone`
or local checkouts — reuse the existing Contents-API helper.

### 4.5 Tasks-stage approve orchestration (resumable)
`approve_feature.handle()` gains a tasks-stage branch. Earlier stages are unchanged. For the tasks
stage it runs a→b→c→d in order, **fail-fast**, and is **resumable**: each step first checks whether it
is already done and skips if so, so re-running approve after a failure continues from where it stopped.

- **a. promote (git):** existing `_commit_files` of the updated `status.yaml` on the feature branch.
  Skip if the branch's `status.yaml` already shows the tasks stage approved.
- **b. ensure docs on base:** §4.4. Skip if the base branch already contains the approved docs (keys off
  content, so an already-merged PR needs no reopening); otherwise merge the single open PR. On merge
  conflict, the genuinely-no-PR case, or >1 open PRs, stop and post a precise message to chat.
- **c. DB status:** existing `update_feature_stage(...)` (`db.py:99`). Idempotent set (safe to re-apply);
  this is what puts the feature into the tasks-approved DB state the §4.7 guard checks.
- **d. create tasks:** §4.3 client, payload from the approved `tasks.md`. The §4.7 backend guard runs
  server-side; the `tasks_already_exist` reason makes a repeat run a safe no-op (treated as "already
  done"). Any other guard error is caught and relayed to chat with the next step.

On any hard failure, approve **returns a clear failure message naming the failed step and instructing
the user to re-run the approve command**; the re-run walks a→b→c→d again, skipping completed steps.
Recovery is the approve command's responsibility — the backup `/create-tasks` (§4.6) is only a
narrow "create tasks" shortcut, never an a/b/c recovery path.

Idempotency summary: a skips on already-approved `status.yaml`; b skips when the base branch already
contains the approved docs (content-keyed, so a merged PR needs no reopening); c is an idempotent set;
d is all-or-nothing with a server-side "already exists" no-op. No step produces partial state that a
re-run cannot safely re-enter.

### 4.6 Backup `/create-tasks` (hermes-internal skill/tool) — step d only
A hermes-internal command — its own version based on the agent-workflow `create-tasks` skill — that the
user triggers from chat. Its **only** job is step d (create tasks); it never performs a (promote), b
(merge), or c (DB status). Use it when a, b, c already succeeded and only task creation remains (or
needs a manual nudge).

It reuses the session's `feature_id` from `plugins/context.get_feature_id()` — it does **not** port the
standalone skill's "Step 1 — Resolve the feature" (arg parsing / candidate scan), which is unnecessary
inside a chat session where the feature is already known. Only a mechanical slug→UUID lookup remains if
the create API requires the UUID. It:
1. calls the §4.3 client for the feature (same API the approve path uses);
2. lets the **§4.7 backend guard** enforce preconditions server-side — it does **not** re-derive
   "approved + merged" from git itself;
3. on a guard error, **relays the issue and the next step to chat** — e.g. `feature_not_tasks_approved`
   → "the tasks stage isn't approved / the docs PR isn't merged yet — **re-run the approve command** to
   complete a→b→c, then retry"; `tasks_already_exist` → "tasks already exist — nothing to do".

Note the guidance points back at the **approve command** for any a/b/c gap — the backup does not attempt
that recovery itself. The agent-workflow `create-tasks` skill remains the reference/CLI variant;
`workflow-mcp`'s `create_tasks` stays a thin API wrapper. Because enforcement is server-side (§4.7),
every one of these callers is guarded uniformly regardless of client-side logic.

### 4.7 Server-side creation guard (workflow-backend)
Add a guard to `CreateTasks` (`internal/service/task_create.go`) that returns a **structured, machine-
readable error** (distinct reason codes) when:
- the feature is **not** in the tasks-approved state (per its DB feature state — `feature_status`
  `ready_for_implementation` following the tasks-stage FSM; exact predicate resolved in implementation),
  reason e.g. `feature_not_tasks_approved`; or
- **tasks already exist** for the feature, reason e.g. `tasks_already_exist` (idempotency).

Rationale for a DB-state check (no git inspection needed): the approve orchestration merges the docs PR
(b) before updating the DB stage (c), so a feature reaching the tasks-approved DB state already implies
the merge in the normal flow. Callers (hermes approve path, hermes backup skill, `workflow-mcp`, the
CLI skill) translate these reason codes into human guidance. The success path and payload shape are
unchanged; this is an additive rejection path.

---

## 5. Dependency analysis

**Internal:**
- §4.3/§4.5-d depend on §4.2 (identity must reach the tool to set `X-User-Id`/`X-Org-Id`).
- §4.5 depends on §4.1 (breakdown must stop writing to the DB, or tasks are double-created), on §4.3
  (task-creation client), on §4.4 (PR-merge helper), and on §4.7 (guard error contract, for step d's
  error relay).
- §4.6 (backup skill) depends on §4.3 (uses the same client) and on §4.7 (relays the guard's reason
  codes).
- §4.7 (backend guard) is independent and can be built in parallel.

**External / configuration (unresolved until ops provisions them):**
- **D1 — hermes → workflow-backend credential + base URL.** `WORKFLOW_BACKEND_URL` and the shared
  service token (`WORKFLOW_BACKEND_SERVICE_TOKEN`, matching what `RequireBFFIdentity` validates) must be
  provisioned in the hermes deployment. Code can be written and unit-tested with placeholders; the live
  approve path is blocked on this. **Unresolved — owner: ops/platform.**
- **GitHub token scope** for merging PRs (the existing `GITHUB_TOKEN` must allow PR merge on the
  management repo). Verify scope; likely already sufficient.

**`workflow-backend` code change** is now required — the §4.7 creation guard (Q4 Option B). No auth/
middleware change (shared-token reuse from Q1 Option A stands); the guard is additive service logic.

---

## 6. Parallelization / blocking analysis

```
D1: Provision hermes → workflow-backend service token + WORKFLOW_BACKEND_URL
      └── code proceeds with placeholders; live approve/create-tasks runtime BLOCKED until provisioned

T1: Identity threading — user_id + org_id into tool context (hermes-agent)
  └── Can begin now — no blockers
T2: write_tasks go-branch stops at tasks.md; remove _insert_tasks_to_db (hermes-agent)
  └── Can begin now — no blockers
T3: workflow-backend creation guard + structured reason codes (workflow-backend)
  └── Can begin now — no blockers
  └── T1, T2, T3 run in parallel
  │
  T4: workflow-backend service client + bulk create call (hermes-agent)
    └── BLOCKED on T1 (identity must reach tool context to set X-User-Id/X-Org-Id headers)
    │
    T5: tasks-stage approve orchestration — resumable a→b→c→d, incl. ensure-docs-on-base + PR merge (hermes-agent)
      └── BLOCKED on T2 (breakdown must stop DB-inserting, else tasks double-created)
      └── BLOCKED on T3 (guard reason codes for step-d error relay + resumable no-op)
      └── BLOCKED on T4 (task-creation client for step d)
      │
      T6: backup /create-tasks — hermes-internal, step d only + guard-error relay (hermes-agent)
        └── BLOCKED on T5 (reuses T5's step-d create logic + guard relay)
        │
        T7: end-to-end verification of the full approve pipeline + backup path (hermes-agent)
          └── BLOCKED on T5 (approve pipeline in place)
          └── BLOCKED on T6 (backup path in place)
```

Wave 1 (parallel, no blockers): T1, T2, T3. Wave 2: T4 (after T1). Wave 3: T5 (after T2+T3+T4). Wave 4:
T6 (after T5). Wave 5: T7 (after T5+T6). D1 gates only the *runtime* of the API-calling work
(T4/T5/T6), not the code. Note: the ensure-docs-on-base + docs-PR-merge helper (§4.4) is folded into
T5, since the approve flow is its only caller.

---

## 7. Repository impact

| Repo (`workspace.yaml` id) | Change |
|---|---|
| `hermes-agent` | Primary. T1 identity threading; T2 `write_tasks` go-branch; T4 backend client; T5 approve orchestration (incl. ensure-docs-on-base + PR merge); T6 backup `/create-tasks` + guard-error relay; T7 tests. |
| `workflow-backend` | T3 — additive creation guard in `CreateTasks` (reject unless tasks-approved; reject if tasks already exist) with structured reason codes. Plus credential/config provisioning (D1). No auth/middleware change. |
| `workflow` | No change required. The agent-workflow `create-tasks` skill is the reference the hermes-internal backup (T6) is based on; it may later adopt the new reason-code handling, but that is not in scope here. |
| `workflow-mcp` | No change. `create_tasks` stays a thin wrapper; the §4.7 server-side guard covers it uniformly. |
| `digital-factory-ui` | Not touched here — board/status UI is the separate `go-orchestrator-status-ui` feature. |

Each task targets exactly one repo (one-repo rule preserved: the `workflow-backend` guard (T3) is a
separate task from all hermes-agent tasks).

---

## 8. Validation and release impact

- **Testing:** unit tests in hermes for the backend client (header construction from threaded identity,
  error surfacing), the approve orchestration's step-b ensure-docs-on-base + PR-merge (already-on-base
  skip; 0/1/many PR cases — 0/many post to chat and halt), and the go-branch `write_tasks` (asserts no DB
  write, `tasks.md` still committed). Go tests in `workflow-backend` for the guard (reject when not
  tasks-approved → `feature_not_tasks_approved`; reject when tasks exist → `tasks_already_exist`; success
  path unchanged). T7 exercises the full approve path end-to-end against a test backend with a placeholder
  token, plus the backup `/create-tasks` recovery (guard rejects early → chat notification, no creation;
  after approve state reached → creation succeeds; tasks-already-exist → safe no-op).
- **Config/migration:** no schema migration. New env in hermes (`WORKFLOW_BACKEND_URL`,
  `WORKFLOW_BACKEND_SERVICE_TOKEN`) — document in hermes' `.env.template` and the operator guide.
- **Rollout:** T1/T3 are safe to ship independently (T3's guard only rejects premature/duplicate
  creation, which nothing does yet). The behavior flip (go tasks created via API at approve instead of at
  breakdown) lands with T5 and requires D1 provisioned first. **Sequencing caution:** T2 (stop the
  premature DB write) must land together with — or after — T5, never before; otherwise go breakdown would
  stop writing tasks while nothing yet creates them at approve, leaving a gap. Recommended release: land
  T1, T3, T4; provision D1; then land T5 and T2 together, followed by T6.
- **Backward compatibility:** ts flow untouched; earlier-stage approvals untouched; identity threading
  is additive (absent identity ⇒ empty strings); the guard is an additive rejection path (success
  unchanged). The only behavioral change is scoped to the go tasks-stage.
- **Handoff:** standard — implementation tasks (Phase 2) run in `hermes-agent` and `workflow`, PRs per
  the workspace conventions.
