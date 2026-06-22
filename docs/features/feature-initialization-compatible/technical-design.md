# Technical Design

## Feature
- Feature ID: `feature-initialization-compatible`
- Title: Feature Initialization — End-to-End Compatible Flow

## Current State

### workflow-backend
- `RegisterRoutes` exposes `GET/POST /workspaces`, `GET /workspaces/:id/features`, etc. — but there is **no `POST /workspaces/:id/features`** route registered. The frontend call lands on a 404.
- `Service` interface has no `CreateFeature` method.
- `WorkspaceService` reads features from the DB (populated by the sync worker). It has no write path for features.
- `internal/github/client.go` already provides `EnsureBranch`, `PutFileContent`, `EnsurePR`, and `ListPRsForBranch`. No `CommitFiles` (multi-file atomic commit) method yet.
- **Already landed (workflow-db merge #34)**: `owner TEXT` column on `workspace_features` and `workspace_tasks` (migration 00015); `Owner *string` on `FeatureSummary` / `TaskSummary` DTOs; service layer maps `owner` through all read paths; `source_path` made nullable for go-owned rows; `feature_id` FK fix (migration 00016).

### workspace-github-adapter
- Handles `workspace:sync` and `task:sync` asynq jobs triggered by GitHub webhooks. A PR merge on any branch already fires a webhook → the adapter enqueues `workspace:sync` automatically.
- Sync worker reads feature YAML/markdown from git and upserts rows into `workspace_features`. It does not currently check or update `init_pr_status`.

### digital-factory-ui
- `NewFeatureModal` sends `{name, description, start_stage}` to `POST /features`. The form has no orchestrator type selector.
- `CreateFeatureRequest` type has no `owner` field.
- `FeatureSummary` and `FeatureDetail` types have no `init_pr_url` / `init_pr_status` fields.
- There is no init-PR section in any feature view component.

### hermes-agent
- Registered tools: `get_workspace_context`, `get_feature_state`, `write_product_spec`, `write_technical_design`, `edit_document`, `get_tasks`, `query_gitnexus`, `query_rag`, `load_skill`, `request_approval`.
- No owner-type branching. Tools that touch git or task-state do not check `status.yaml`'s `owner` field before acting.

## Problem Framing

Three independent gaps must close:

1. **Missing backend**: `POST /features` is not implemented. The DB has no column for orchestrator type.
2. **Missing UI affordances**: The create-feature modal has no orchestrator type selector; the feature detail view has no init PR link.
3. **Hermes is owner-blind**: It does not distinguish `ts` from `go` when writing task files or creating branches, and cannot surface the init PR link to the user.

What must remain stable:
- The existing workspace sync path (workspace-github-adapter → webhook → task queue → DB write).
- All existing read endpoints (`GET /features`, `GET /features/:id`, `GET /features/:id/tasks`, etc.).
- Existing Hermes tools — the owner-awareness change is additive: when `owner` is absent or `ts`, existing behaviour is preserved.

Fixed assumptions:
- The GitHub token available to workflow-backend is sufficient to create branches, commit files, and open PRs on the management repo.
- The management repo URL is derivable from the workspace record (via the existing `githubRepoURL` helper).
- Git-init runs synchronously in the create-feature handler. The PR URL is known before 201 is returned. We accept the ~1–2 s latency.
- Merge is performed by the user directly on GitHub. The adapter's webhook-triggered sync is the mechanism that updates `init_pr_status` to `merged` — no dedicated merge API endpoint is needed.

## Options Considered

### Option A — Synchronous git-init inside workflow-backend
- workflow-backend calls the GitHub REST API directly using its existing `github.Client` to create the branch, commit template files, and open the PR — all within the `POST /features` handler.
- Pros: Simple. PR URL available in the 201. No new queue job or async state machine. `github.Client` already has `EnsureBranch`, `PutFileContent`, `EnsurePR`.
- Cons: ~1–2 s added to feature creation latency. GitHub API failures surface as 5xx.
- Implementation impact: Add `CreateFeature` to `Service` interface and `WorkspaceService`. Add `CommitFiles` to `github.Client`. Embed template files as Go strings. No DB migration — `owner` column already exists.
- Dependency impact: `GITHUB_TOKEN` with write scope confirmed (D1 resolved).

### Option B — Async git-init via asynq to workspace-github-adapter
- workflow-backend creates the DB record, enqueues a `feature:git-init` asynq task. workspace-github-adapter executes it. UI polls until `init_pr_url` is populated.
- Pros: Non-blocking.
- Cons: PR URL not in the 201 — UI must poll. New queue job type needed. Adds async failure modes. UI needs a loading/polling state.
- Implementation impact: High — spans two services plus UI polling logic.

## Chosen Design

**Option A — synchronous git-init inside workflow-backend.**

Rationale: Git-init creates 4–5 small text files and opens one PR. GitHub REST API p95 for these operations is well under 2 s. The synchronous path keeps implementation entirely in workflow-backend, delivers the PR URL in the 201, and eliminates async failure modes. Option B's complexity is not justified.

### Affected repositories
- `workflow-backend` — new `POST /features` endpoint, DB migration, GitHub git-init logic
- `workspace-github-adapter` — update sync to detect merged init PR and write `init_pr_status = 'merged'`
- `digital-factory-ui` — orchestrator type selector, init PR link display
- `hermes-agent` — owner-type branching, init PR link as interactive button in chat

### Git-init commit strategy
`PutFileContent` creates one commit per file. To produce a single clean init commit, we add a `CommitFiles(ctx, owner, repo, branch, baseBranch, message string, files map[string]string) error` method to `github.Client` using the GitHub Git Data API: create blobs → create tree → create commit → update ref.

### Template files (embedded Go strings)
Template files are embedded in workflow-backend as Go string constants:

| Path | `ts` feature | `go` feature |
|---|---|---|
| `docs/features/{id}/product-spec.md` | ✓ | ✓ |
| `docs/features/{id}/technical-design.md` | ✓ | ✓ |
| `docs/features/{id}/status.yaml` | `owner` absent | `owner: go` |
| `docs/features/{id}/tasks/.gitkeep` | ✓ | — |
| `docs/features/{id}/handoffs/.gitkeep` | ✓ | ✓ |

### DB schema — no migration needed
The `owner TEXT` column already exists on `workspace_features` (migration 00015, landed in workflow-db merge). No further schema changes are required for this feature.

`init_pr_url` and `init_pr_status` are not stored. The init PR branch is always `feature/<feature_id>-init` — deterministic from the feature ID. workflow-backend returns `init_pr_url` as a computed field in the `POST /features` 201 response (constructed from the workspace management repo URL + branch name) without persisting it. The adapter's existing webhook-triggered sync already re-reads git state on every PR event; no additional status tracking is needed.

### New API endpoint (single)

```
POST /api/workspaces/:workspaceId/features
  Body: { name, description?, owner }   owner: "ts" | "go"
  201:  FeatureSummary + init_pr_url (computed, not persisted)
```

No merge endpoint. No adapter change. The user merges the PR directly on GitHub.

### UI init PR section
The feature detail view renders an "Init PR" banner using the `init_pr_url` returned in the `POST /features` 201 response and cached in frontend state. The banner shows a "View on GitHub" link that opens the PR in a new tab. No API call is needed to check merge status — the banner is a static link, not a stateful widget.

### Hermes owner-type branching
Before any owner-dependent action (write task YAML, create git branch for task state), tools read `feature_state["owner"]` from the DB-backed `get_feature_state` result. When `owner == "go"`, the tool skips the git/YAML operation and returns a descriptive message. When `owner == "ts"` or absent, existing behaviour is unchanged.

Hermes surfaces the init PR link as a clickable button in its response when `feature_state["init_pr_url"]` is non-null and `init_pr_status == "open"`. No tool call is needed — this is a read-only display in the chat response.

## Dependency Analysis

### Internal dependencies
- T1 (`workflow-backend`) must be complete before T2 and T3 — T2 needs `init_pr_url` in the feature creation response; T3 needs the `owner` column populated for new features.
- T2 (`digital-factory-ui`) and T3 (`hermes-agent`) are independent of each other and run in parallel once T1 merges.

### External dependencies
- `GITHUB_TOKEN` with write scope (branch create + PR open) on the management repo — **confirmed (D1 resolved)**.

### Blocking decisions
- None. D1 is resolved.

### Unresolved
- None.

## Parallelization / Blocking Analysis

```
T1: workflow-backend — DB migration (owner column) + CreateFeature endpoint + GitHub git-init
  └── Can begin now — D1 confirmed, no blockers

  T2: digital-factory-ui — orchestrator selector + init PR link banner
      └── BLOCKED on T1 (needs init_pr_url in POST /features response)

  T3: hermes-agent — owner-type branching + init PR link button in chat
      └── BLOCKED on T1 (owner column must be populated for new features)
```

T2 and T3 run in parallel once T1 merges.

## Repository Impact

| Repo | Changes |
|---|---|
| `workflow-backend` | No new migration (`owner` column already landed in workflow-db); `CreateFeature` added to `Service` interface and `WorkspaceService`; `CommitFiles` added to `github.Client`; one new route in handler; embedded template strings; `init_pr_url` returned as computed field in 201 response |
| `digital-factory-ui` | Updated types (`CreateFeatureRequest`, `FeatureSummary`); orchestrator type selector in `NewFeatureModal`; init-PR banner (link only, no API call) shown after feature creation |
| `hermes-agent` | Owner-type guard added to owner-dependent tools; init PR link rendered as interactive button in chat |

Repos not affected: `workflow`, `workflow-orchestrator`, `workflow-bff`, `workspace-github-adapter`, `rag-service`, `git-nexus`, `user-service`.

## Validation and Release Impact

### Testing expectations
- **workflow-backend**: Unit tests for `CreateFeature` service method with a mock `github.Client`. Unit test for `CommitFiles` GitHub method. Existing handler tests must still pass. No migration test update needed — `owner` column already covered by workflow-db tests.
- **digital-factory-ui**: Component test for `NewFeatureModal` with the orchestrator selector. Smoke test: create feature → verify init PR banner appears with correct link.
- **hermes-agent**: Owner-type guard tested with both `ts` and `go` feature states. Init PR button tested with a feature state that has `init_pr_url` set.

### Migration / config impact
- No new migration required — `owner` column already exists (migration 00015, workflow-db merge). Existing rows have `owner = NULL` (interpreted as `ts`), which is fully backward compatible.
- `GITHUB_TOKEN` with write scope is confirmed present in workflow-backend environment (D1 resolved).

### Rollout concerns
- Features created before this ships have `init_pr_url = NULL`. UI must handle gracefully — no banner if null. No backfill needed.
- The `owner = NULL` → `ts` default preserves all existing feature records.

### Backward compatibility
- All existing read endpoints unchanged.
- Existing Hermes tools unchanged when `owner` is absent or `ts`.
- `start_stage` is ignored by the new endpoint (init always starts at `in_design`). UI should drop it from the payload; the backend ignores unknown fields, so this is non-breaking.
