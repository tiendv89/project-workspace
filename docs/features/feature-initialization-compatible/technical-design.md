# Technical Design

## Feature
- Feature ID: `feature-initialization-compatible`
- Title: Feature Initialization — End-to-End Compatible Flow

## Current State

### workflow-backend
- `RegisterRoutes` exposes `GET/POST /workspaces`, `GET /workspaces/:id/features`, etc. — but there is **no `POST /workspaces/:id/features`** route registered. The frontend call lands on a 404 (or gin's default 404 body).
- `Service` interface has no `CreateFeature` or `MergeInitPR` method.
- `WorkspaceService` reads features from the DB (populated by the sync worker). It has no write path for features.
- `internal/github/client.go` already provides `EnsureBranch`, `PutFileContent`, `EnsurePR`, and `ListPRsForBranch`. There is no `MergePR` method.
- `workspace_features` DB table has no `owner`, `init_pr_url`, or `init_pr_status` columns.

### digital-factory-ui
- `NewFeatureModal` sends `{name, description, start_stage}` to `POST /features`. The form has no orchestrator type selector.
- `CreateFeatureRequest` type has no `owner` field.
- `FeatureSummary` and `FeatureDetail` types have no `init_pr_url` / `init_pr_status` fields.
- There is no "Merge Init PR" button or init-PR section in any feature view component.

### hermes-agent
- Registered tools: `get_workspace_context`, `get_feature_state`, `write_product_spec`, `write_technical_design`, `edit_document`, `get_tasks`, `query_gitnexus`, `query_rag`, `load_skill`, `request_approval`.
- No `merge_init_pr` tool.
- No owner-type branching. Tools that touch git or task-state do not check `status.yaml`'s `owner` field before acting.

## Problem Framing

Three independent gaps must close:

1. **Missing backend**: `POST /features` and `POST /features/:id/merge-init-pr` do not exist. The DB has no columns for owner type or init PR state.
2. **Missing UI affordances**: The create-feature modal passes no `owner`; the feature detail view has nowhere to show the init PR or a merge button.
3. **Hermes is owner-blind**: It does not distinguish `ts` from `go` when writing task files or creating branches. It also cannot merge an init PR from chat.

What must remain stable:
- Existing feature sync path (workspace-github-adapter → webhook → task queue → DB write). This feature does not change it.
- All existing read endpoints (`GET /features`, `GET /features/:id`, `GET /features/:id/tasks`, etc.) must continue working unchanged.
- Existing Hermes tools — no regressions. The owner-awareness change is additive: when `owner` is absent or `ts`, existing behaviour is preserved.

Fixed assumptions:
- The GitHub token available to workflow-backend is sufficient to create branches, commit files, open PRs, and merge PRs on the management repo.
- The management repo URL is derivable from the workspace record (via the existing `githubRepoURL` helper).
- Git-init is synchronous within the create-feature request. The PR URL is known before the 201 is returned. We accept the ~1–2 s latency this adds to feature creation.

## Options Considered

### Option A — Synchronous git-init inside workflow-backend
- Workflow-backend calls the GitHub REST API directly using its existing `github.Client` to create the branch, commit template files, and open the PR. All within the `POST /features` request handler.
- Pros: Simple. PR URL is available in the 201 response. No new queue job type or async state machine. Existing `github.Client` already has `EnsureBranch`, `PutFileContent`, `EnsurePR`.
- Cons: ~1–2 s added to feature creation latency. GitHub API failures surface as 5xx to the caller.
- Implementation impact: Add `CreateFeature`/`MergeInitPR` to `Service` interface and `WorkspaceService`. Add `MergePR` to `github.Client`. Embed template files as Go strings.
- Dependency impact: Requires `GITHUB_TOKEN` in workflow-backend config (may already be present; confirm before implementation).

### Option B — Async git-init via asynq queue to workspace-github-adapter
- Workflow-backend creates the DB record (status `init_pending`), enqueues a new `feature:git-init` asynq task. workspace-github-adapter executes it asynchronously. UI polls `GET /features/:id` until `init_pr_url` is populated.
- Pros: Non-blocking request. Consistent with existing workspace:sync pattern.
- Cons: PR URL not available in the 201 — UI must poll. New queue job type and worker handler needed in workspace-github-adapter. Adds async failure modes (job lost, retry exhausted). UI needs a loading/polling state for init PR.
- Implementation impact: High. Spans three services.
- Dependency impact: asynq / Redis must be reachable from workspace-github-adapter (it already is, but adds coupling).

## Chosen Design

**Option A — synchronous git-init inside workflow-backend.**

Rationale: Git-init creates 4–5 small text files and opens one PR. GitHub REST API p95 for these operations is under 2 s total. The synchronous path keeps the implementation entirely within workflow-backend, eliminates async failure modes, and delivers the PR URL in the 201 so the UI can show it immediately without polling. Option B's complexity is not justified by the latency savings.

### Affected repositories
- `workflow-backend` — new endpoint, DB migration, GitHub git-init/merge logic
- `digital-factory-ui` — orchestrator type selector, init PR display, merge button
- `hermes-agent` — `merge_init_pr` tool, owner-type branching

### Git-init commit strategy
The existing `PutFileContent` creates one commit per file. For a clean init commit history we will add a `CommitFiles(ctx, owner, repo, branch, baseBranch, message, files map[string]string)` method to `github.Client` using the GitHub Git Data API (create blobs → create tree → create commit → update ref). This produces a single atomic commit for all template files rather than 5 sequential commits.

### Template files (embedded Go strings)
Template files are embedded in workflow-backend as Go string constants (no filesystem dependency at runtime):

| Path | `ts` feature | `go` feature |
|---|---|---|
| `docs/features/{id}/product-spec.md` | ✓ | ✓ |
| `docs/features/{id}/technical-design.md` | ✓ | ✓ |
| `docs/features/{id}/status.yaml` | `owner` absent | `owner: go` |
| `docs/features/{id}/tasks/.gitkeep` | ✓ | — |
| `docs/features/{id}/handoffs/.gitkeep` | ✓ | ✓ |

### DB schema additions (new migration)
```sql
ALTER TABLE workspace_features
  ADD COLUMN IF NOT EXISTS owner          TEXT,          -- null = ts (legacy), 'go' = go orchestrator
  ADD COLUMN IF NOT EXISTS init_pr_url    TEXT,          -- GitHub PR HTML URL
  ADD COLUMN IF NOT EXISTS init_pr_status TEXT;          -- 'open' | 'merged' | null (not yet created)
```

### New API endpoints

```
POST /api/workspaces/:workspaceId/features
  Body: { name, description?, owner }   owner: "ts" | "go"
  201:  FeatureSummary + init_pr: { url, status }

POST /api/workspaces/:workspaceId/features/:featureId/merge-init-pr
  (no body)
  200:  updated FeatureSummary
```

### Hermes `merge_init_pr` tool
Calls `POST /bff/workflow-backend/api/workspaces/:workspaceId/features/:featureId/merge-init-pr`. Returns `{"ok": true, "merged_pr_url": "..."}` on success. Registered with `check_fn: check_workflow_available` alongside existing tools.

### Hermes owner-type branching
Before any owner-dependent action (write task YAML, create git branch for task state), tools read `feature_state["owner"]` from the DB-backed `get_feature_state` result. When `owner == "go"` or `owner` is `None`, the tool skips the operation and returns a descriptive message. When `owner == "ts"` (or absent), existing behaviour is unchanged.

### UI interactive "Merge Init PR" button
The feature detail view (`feature-workbench.tsx` or a new `init-pr-banner.tsx`) renders a banner when `feature.init_pr_status == "open"`. The banner shows the PR URL and a "Merge Init PR" button that calls `mergeInitPR(workspaceId, featureId)` in the workflow-backend client. On success, optimistic-updates `init_pr_status` to `"merged"` and hides the banner.

## Dependency Analysis

### Internal dependencies
- T1 (`workflow-backend`) must be complete before T2's merge button can be wired to a real endpoint, and before T3's `merge_init_pr` tool can call it.
- T2 (`digital-factory-ui`) depends on T1 for the `init_pr_url` / `init_pr_status` fields in the feature response and the merge endpoint.
- T3 (`hermes-agent`) depends on T1 for the merge endpoint. Owner-type awareness within T3 is independent — it reads from `feature_state["owner"]` which already exists in the DB (once T1 adds the column and populates it for new features).

### External dependencies
- `GITHUB_TOKEN` must be available in workflow-backend's environment with write scope on the management repo. **This must be confirmed by the human before T1 begins.**
- GitHub REST API availability (no known blocker; already used by workflow-backend for document reads/writes).

### Blocking decisions
- **D1**: Confirm `GITHUB_TOKEN` scope in workflow-backend config. If absent, T1 must add it to the config struct and `.env` before git-init logic can work.

### Unresolved
- None beyond D1.

## Parallelization / Blocking Analysis

```
D1: Confirm GITHUB_TOKEN write-scope in workflow-backend config
  └── Resolve before T1 implementation begins (check with pye — likely already present)

T1: workflow-backend — DB migration + CreateFeature + MergeInitPR endpoints + GitHub git-init
  └── Can begin now (pending D1 confirm)
  └── BLOCKED on D1 (GITHUB_TOKEN needed for git-init calls)

  T2: digital-factory-ui — orchestrator selector + init PR display + merge button
      └── BLOCKED on T1 (needs init_pr_url/init_pr_status in feature response; needs merge endpoint)

  T3: hermes-agent — merge_init_pr tool + owner-type awareness
      └── Owner-type awareness sub-work: Can begin now — reads owner from existing feature_state
      └── merge_init_pr tool: BLOCKED on T1 (merge endpoint must exist to call)
      └── In practice: implement both sub-works together once T1 is merged
```

T2 and T3 run in parallel once T1 is merged.

## Repository Impact

| Repo | Changes |
|---|---|
| `workflow-backend` | New DB migration; new `CreateFeature` / `MergeInitPR` on `Service` interface and `WorkspaceService`; new `CommitFiles` + `MergePR` on `github.Client`; two new routes in handler; embedded template strings |
| `digital-factory-ui` | Updated types (`CreateFeatureRequest`, `FeatureSummary`, `FeatureDetail`); updated `NewFeatureModal`; new init-PR banner component; new `mergeInitPR` API client call |
| `hermes-agent` | New `merge_init_pr` tool and schema; owner-type guard added to owner-dependent tools; new tool registered in `plugins/__init__.py` |

Repos not affected: `workflow`, `workflow-orchestrator`, `workflow-bff`, `rag-service`, `git-nexus`, `workspace-github-adapter`, `user-service`.

## Validation and Release Impact

### Testing expectations
- **workflow-backend**: Unit tests for `CreateFeature` and `MergeInitPR` service methods with a mock `github.Client`. Integration test (using a real or stubbed GitHub API) for git-init happy path. Existing handler tests must still pass.
- **digital-factory-ui**: Component test for `NewFeatureModal` with the orchestrator selector. E2E or smoke test: create feature → verify init PR banner appears.
- **hermes-agent**: Unit test for `merge_init_pr` tool with a mocked HTTP call to the backend endpoint. Owner-type guard tested with both `ts` and `go` feature states.

### Migration / config impact
- One new migration (`ALTER TABLE workspace_features ADD COLUMN ...`). Nullable columns with no default constraint — fully backward compatible. Existing feature rows will have `owner = NULL` (interpreted as `ts`), `init_pr_url = NULL`, `init_pr_status = NULL`.
- `GITHUB_TOKEN` with write scope must be present in workflow-backend environment (confirm D1).

### Rollout concerns
- Features created before this change ship will have `init_pr_url = NULL`. The UI must handle this gracefully (no banner if null). No backfill required — existing features were initialized manually.
- The `owner` column being nullable and defaulting to `ts` semantics preserves all existing feature records without a data migration.

### Backward compatibility
- All existing read endpoints unchanged.
- Existing Hermes tools retain current behaviour when `owner` is absent or `ts`.
- `start_stage` field removed from the API request (it was never used by the backend; init always starts at `in_design`). UI should remove it from the payload — but since the backend ignores unknown fields, this is non-breaking.
