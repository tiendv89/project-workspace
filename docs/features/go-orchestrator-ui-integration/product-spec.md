# Product Specification

## Feature
- Feature ID: `go-orchestrator-ui-integration`
- Title: Go orchestrator — Hermes tasks-stage approve pipeline (merge docs PR + create tasks via API)
- Tracked with: `ts` flow (per-task YAML state in `tasks/`). Note this is about how *this feature's own*
  tasks are tracked — the go orchestrator it builds is still in development, so this feature is not
  itself `owner: go`. The functionality being built is entirely for the `go` flow.

## Summary

Make the `go`-orchestrator feature lifecycle work end-to-end through the Hermes chat, all the way to
tasks landing in the orchestrator database. Today the final step is broken: when `tech-lead` breaks
down tasks, Hermes writes the `go` task rows straight into Postgres — during the breakdown turn, before
the human approves the tasks stage, before the docs PR is merged, and bypassing the validating
`workflow-backend` API. This feature moves task creation to where it belongs: the human-gated
tasks-stage **approve** command, which becomes the single action that promotes the feature, merges the
docs PR, updates the database, and creates the tasks via the API. A precondition-checked backup
`/create-tasks` command covers partial failures.

## Problem

For a `go`-owned feature, the intended human-facing lifecycle runs entirely through the
`digital-factory-ui` chat panel, which is fronted by **hermes-agent** (a Python/FastAPI agent gateway
that owns the `approve_feature` and `write_tasks` tools):

1. Draft and approve the product spec.
2. Draft and approve the technical design.
3. Break down tasks for human review.
4. On the final tasks-stage approval, actually land the tasks in the orchestrator database.

Step 4 is broken/incomplete:

- **Premature, API-bypassing task creation.** `write_tasks` (`hermes-agent`
  `plugins/tools/tasks_write.py`) correctly commits a full `tasks.md` narrative to git for every owner.
  But for `owner == "go"` it *also* immediately writes task rows straight into `workflow-backend`'s
  Postgres via `_insert_tasks_to_db()` (`tasks_write.py:428-436`) — in the breakdown turn, before the
  human has approved the tasks stage and before the docs PR is merged. This bypasses the validating
  `POST /api/workspaces/:workspaceId/features/:featureId/tasks` API and is the "known third-writer
  risk" flagged as a tracked follow-up in the `workflow-db` technical design.

- **No single command that finishes the job.** `approve_feature` only flips the stage's review status;
  it does not merge the docs PR or create tasks. So there is no correct, human-gated action that
  promotes the feature → merges the docs PR → updates the DB → creates the tasks. The only way tasks
  reach the DB today is the premature shortcut above.

The result: a `go` feature cannot be driven cleanly from breakdown to ready-for-implementation through
the chat, and the tasks that do land skip validation.

## Goals

- `tech-lead` Phase 2 (`write_tasks`) produces **`tasks.md` only** for `go` features — a comprehensive
  narrative for human review, no `tasks/` folder, and **no database write**.
- The **tasks-stage approve command** is the single human-gated action that, in one command, does all
  of:
  1. promotes the feature's status to the next stage in git (commits `status.yaml` on the feature
     branch);
  2. merges the management-repo docs PR (feature branch → `main`);
  3. updates the feature's status in the orchestrator database;
  4. creates the tasks by calling `workflow-backend`'s validating tasks API.
- Task creation goes through the **`workflow-backend` API** (`POST /api/.../tasks`) — never a direct DB
  insert and never through `workflow-bff` (whose proxy is browser-session-cookie only and has no
  service-to-service path).
- A backup **`/create-tasks`** command lets a human recover when approve-time task creation fails. It
  verifies the tasks stage is approved **and** the docs PR is merged to `main` before creating tasks;
  if not, it tells the human to update/merge the docs PR first and retry. It does **not** merge the PR
  itself.
- `workflow-backend` remains the single validating writer of `go` task state.

## Non-goals

- **`digital-factory-ui` board / task-list UI gaps.** Surfacing `owner: go` features/tasks visually and
  rendering go-specific statuses (`reviewing`, `review_passed`, `review_incomplete`, `blocked_details`)
  is deferred to a separate follow-up feature (`go-orchestrator-status-ui`).
- **Changing earlier-stage approvals.** Approving the `product_spec` and `technical_design` stages keeps
  its current promote-only behavior. One docs PR accumulates spec + design + tasks and is merged only at
  the tasks stage.
- **Building an MCP server** for hermes → workflow-backend. The intended pattern is a typed HTTP client
  (see the existing `hermes-agent` `src/services/user_service_client.py`). MCP is revisited only if the
  technical design finds it necessary.

## Target flow (end to end)

1. Human creates a `go`-owned feature in `digital-factory-ui` (`new-feature-modal.tsx` — already built).
2. `tech-lead` Phase 1 drafts `product-spec.md` / `technical-design.md` through the Hermes chat; the
   human approves each stage via the chat approval card (`approval-card.tsx` → `approve_feature`). Status
   is promoted and the flow moves on. The docs PR is **not** merged yet.
3. `tech-lead` Phase 2 runs `write_tasks`, which creates **`tasks.md` only** for human review — no
   `tasks/` folder, no DB insert.
4. The human reviews `tasks.md` and runs the **tasks-stage approve command**. Hermes, in that one
   command:
   a. promotes the feature's status to the next stage in git (commit `status.yaml` on the feature branch);
   b. merges the management-repo docs PR (feature branch → `main`);
   c. updates the feature's status in the orchestrator database;
   d. creates the tasks by calling `workflow-backend`'s `POST /api/.../tasks`.
5. If step 4d fails (a partial approve), the human runs the backup **`/create-tasks`** command. It first
   verifies the tasks stage is approved **and** the docs PR is merged to `main`. If either is missing, it
   notifies the human to update/merge the docs PR before retrying. If preconditions hold, it creates the
   tasks via the same API.

## Scope of change (repos)

- **hermes-agent** (primary):
  1. `write_tasks` stops at `tasks.md` for `go` — remove the `owner == "go"` call to
     `_insert_tasks_to_db()`; the breakdown turn only commits `tasks.md` (like the ts branch, minus the
     per-task YAMLs).
  2. The tasks-stage `approve_feature` path additionally merges the docs PR and creates tasks via the
     API (the four actions in step 4). Earlier-stage approvals unchanged.
  3. New `workflow-backend` HTTP client (service-to-service) for `POST /api/.../tasks`, modeled on
     `user_service_client.py` (raw `aiohttp` + Bearer). Prerequisite: fix the broken `org_id` threading
     — `identity.py` extracts `org_id`, but `chat.py` drops it before `agent_dispatch.py` /
     `plugins/context.py`, so tools never receive it.
  4. PR-merge capability, extending the existing GitHub git-data-API usage in
     `tasks_write.py::_commit_files`.
  5. The backup `/create-tasks` command with its precondition check and human notification.
- **workflow-backend**: possibly a dedicated service credential for Hermes (see open questions);
  the tasks API and `RequireBFFIdentity` middleware already exist and are unchanged in shape.

## Constraints / architectural facts

- **`workflow-bff` cannot proxy Hermes → workflow-backend.** Its proxy authenticates a live browser
  `session_id` cookie only; it strips inbound `Authorization`/`Cookie` headers and has no
  service-to-service path. Hermes must call `workflow-backend` directly.
- **`workflow-backend`'s tasks API expects `RequireBFFIdentity`**: a Bearer service token plus
  `X-User-Id` / `X-Org-Id` / `X-Accessible-Org-Ids` headers. Hermes must present a valid service
  credential and set the identity headers from the calling user's identity.
- **Feature status DB sync** is otherwise handled by `workspace-github-adapter`'s git→DB scan of
  `status.yaml` — the approve command's direct DB status update (4c) is an immediacy optimization on top
  of that existing sync, not a replacement.

## Open technical-design questions (for `tech-lead`)

- **Service credential**: how Hermes obtains/presents a token `RequireBFFIdentity` accepts — reuse the
  BFF's shared service token, or provision a dedicated Hermes credential (a possible `workflow-backend`
  change)?
- **Docs-PR tracking**: how Hermes locates the docs PR to merge — PR number/URL stored in `status.yaml`,
  discovered via the GitHub API by branch, or otherwise?
- **Failure / atomicity ordering** across the four approve actions (4a–4d): define an ordering and
  idempotent behavior for partial failures. The backup `/create-tasks` recovers the "merge succeeded but
  create-tasks failed" case; other orderings (e.g. promote succeeded, merge failed) need defined
  behavior.
- **Where `/create-tasks` lives**: a Hermes tool/skill, or the existing `create-tasks` skill /
  `workflow-mcp` command extended with the approval+merge precondition re-check.

## Already built (confirm, do not rebuild)

- go/ts orchestrator selector at feature creation: `digital-factory-ui` `new-feature-modal.tsx`.
- Stage approval UI: `approval-card.tsx` → hermes `approve_feature`.
- `workflow-backend` tasks API + `RequireBFFIdentity` (`internal/handler/workspace.go`,
  `internal/service/task_create.go`, `internal/authmw/bff_identity.go`).
- `workspace-github-adapter` git→DB sync of feature status.
