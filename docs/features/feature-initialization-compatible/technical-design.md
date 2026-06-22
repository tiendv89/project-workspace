# Technical Design

## Feature
- Feature ID: `feature-initialization-compatible`
- Title: Feature Initialization — End-to-End Compatible Flow

## Current State

### workflow-backend
- `RegisterRoutes` has no `POST /workspaces/:id/features` route. Frontend call lands on a 404.
- `Service` interface has no `CreateFeature` method. `WorkspaceService` has no feature write path.
- `internal/github/client.go` provides `EnsureBranch`, `PutFileContent`, `EnsurePR`, `ListPRsForBranch`. No `CommitFiles` (multi-file atomic commit) yet.
- **Already landed (workflow-db merge #34)**: `owner TEXT` column on `workspace_features` and `workspace_tasks` (migration 00015); `Owner *string` on `FeatureSummary` / `TaskSummary` DTOs; service layer maps `owner` through all read paths; `source_path` nullable; `feature_id` FK fixed (migration 00016).
- `init_pr_url` is not stored anywhere.

### digital-factory-ui
- `NewFeatureModal` sends `{name, description, start_stage}` — no `owner` field.
- `FeatureSummary` / `FeatureDetail` types have no `init_pr_url`.
- No init PR section in any feature view component.

### hermes-agent
- `write_product_spec` and `write_technical_design` tools write documents but do not commit to an init PR branch — they write directly without ensuring a PR exists.
- No owner-type branching. Tools do not read `owner` before git or task-state operations.
- `request_approval` tool surfaces an Approve/Reject card in chat and sets `review_status = awaiting_approval` in the DB — this is already the mechanism for gating the approve button in the feature detail view.

## Problem Framing

Four gaps must close:

1. **Missing backend**: `POST /features` is not implemented. `init_pr_url` is not stored in the DB.
2. **Missing UI affordances**: No orchestrator type selector in the create modal; no init PR link in the feature detail view.
3. **Hermes document tools don't commit to init PR**: `write_product_spec` and `write_technical_design` write documents without ensuring an init PR branch exists and without committing to it.
4. **Hermes is owner-blind**: Tools do not distinguish `ts` from `go` when writing task files or creating branches.

What must remain stable:
- Existing workspace sync path (workspace-github-adapter → webhook → DB write).
- All existing read endpoints.
- Existing Hermes tools — owner-awareness is additive; absent/`ts` preserves current behaviour.

Fixed assumptions:
- `GITHUB_TOKEN` with write scope on the management repo is confirmed present in workflow-backend (D1 resolved).
- Management repo URL is derivable from the workspace record via `githubRepoURL`.
- Git-init runs synchronously in the `POST /features` handler. PR URL is known before 201 is returned. ~1–2 s latency accepted.
- User merges the init PR directly on GitHub — no merge endpoint needed.
- The approve button in the feature detail is already gated by `review_status = awaiting_approval`, which Hermes sets via `request_approval` after writing a document. No additional UI gatekeeping logic is required.

## Options Considered

### Option A — Synchronous git-init inside workflow-backend (chosen)
- `POST /features` creates the DB record and immediately calls GitHub to create the branch, commit template files, and open the PR. `init_pr_url` stored and returned in the 201.
- Pros: PR URL available in the 201. No polling. No new queue job. `github.Client` already has the primitives.
- Cons: ~1–2 s added to feature creation latency. GitHub API failures surface as 5xx.

### Option B — Async git-init via asynq
- DB record created first, git-init enqueued. UI polls until `init_pr_url` is populated.
- Cons: PR URL not in 201, UI must poll, new queue job type, async failure modes.
- Rejected: complexity not justified for a small one-time operation.

## Chosen Design

**Option A — synchronous git-init inside workflow-backend.**

Both `ts` and `go` features follow the same initialization flow. The only difference is which template files go on the init branch and how task state is stored later. The init PR is always created eagerly at feature creation — Hermes document tools commit to the existing branch and have a fallback "create init PR if missing" guard for robustness.

### Full flow

```
POST /features {name, description, owner}
  → Create workspace_features row (owner set, init_pr_url null initially)
  → git-init:
      create branch  feature/<feature_id>-init  from main
      commit template files (owner-specific set, see below)
      open PR: feature/<feature_id>-init → main
  → save init_pr_url to DB
  → 201: FeatureSummary with init_pr_url

User opens feature detail
  → init PR link shown (View on GitHub)
  → no approve button yet (review_status = draft)

User chats with Hermes: "write the product spec"
  → write_product_spec:
      get feature_state → read init_pr_url
      if init_pr_url missing (fallback): create init PR, save URL
      commit product-spec.md content to init PR branch
      call request_approval(stage: "product_spec")
      return PR link as interactive button in chat
  → review_status = awaiting_approval
  → approve button appears in feature detail

User approves product spec → stage advances to technical_design
  → same pattern for write_technical_design
```

### ts vs go template files

| Path | `ts` feature | `go` feature |
|---|---|---|
| `docs/features/{id}/product-spec.md` | ✓ | ✓ |
| `docs/features/{id}/technical-design.md` | ✓ | ✓ |
| `docs/features/{id}/status.yaml` | `owner` absent | `owner: go` |
| `docs/features/{id}/tasks/.gitkeep` | ✓ | — |
| `docs/features/{id}/handoffs/.gitkeep` | ✓ | ✓ |

Template files are embedded in workflow-backend as Go string constants. Template selection is based on the `owner` field in the `POST /features` request.

### Git-init commit strategy
Add `CommitFiles(ctx, owner, repo, branch, baseBranch, message string, files map[string]string) error` to `github.Client` using the GitHub Git Data API (create blobs → create tree → create commit → update ref). Single atomic commit for all template files.

### DB schema
One new migration — `init_pr_url TEXT` on `workspace_features`. `owner` already exists.

```sql
ALTER TABLE workspace_features
  ADD COLUMN IF NOT EXISTS init_pr_url TEXT;  -- GitHub PR HTML URL, set at feature creation
```

`init_pr_url` is null for features created before this feature ships. The UI and Hermes must handle null gracefully (no banner, no button).

### New API endpoint

```
POST /api/workspaces/:workspaceId/features
  Body: { name, description?, owner }   owner: "ts" | "go"
  201:  FeatureSummary (includes init_pr_url, owner)
```

`FeatureSummary` already has `Owner *string`. Add `InitPRURL *string json:"init_pr_url,omitempty"`.

### Hermes document tool updates
Both `write_product_spec` and `write_technical_design` follow the same pattern:
1. Call `get_feature_state` → read `init_pr_url` and `owner`.
2. If `init_pr_url` is null (fallback guard): call workflow-backend `POST /features/:id/ensure-init-pr` or create directly via GitHub API and persist the URL.
3. Commit the document content to the init PR branch via `PutFileContent` (management repo GitHub API).
4. Call `request_approval(stage: <product_spec|technical_design>)` to set `review_status = awaiting_approval`.
5. Return the PR link as a clickable interactive button in the chat response.

### Hermes owner-type branching
Before any owner-dependent operation (write task YAML, create task branch), tools read `feature_state["owner"]`. When `owner == "go"`, git/YAML operations are skipped with a descriptive message. When `owner == "ts"` or absent, existing behaviour is unchanged.

### UI feature detail changes
- Add `init_pr_url` to `FeatureSummary` / `FeatureDetail` TypeScript types.
- Render an "Init PR" section when `init_pr_url` is non-null: a "View on GitHub" link (opens in new tab). Static link — no API call.
- Approve button display is already handled by existing `review_status = awaiting_approval` logic (Hermes sets this via `request_approval`). No new UI gating logic needed.

## Dependency Analysis

### Internal dependencies
- T1 (`workflow-backend`) must be complete before T2 and T3: T2 needs `init_pr_url` in the feature response; T3's Hermes tools need the init PR to exist and `init_pr_url` to be readable from `get_feature_state`.
- T2 (`digital-factory-ui`) and T3 (`hermes-agent`) are independent of each other — run in parallel once T1 merges.

### External dependencies
- `GITHUB_TOKEN` write scope — **confirmed (D1 resolved)**.

### Blocking decisions
- None.

### Unresolved
- None.

## Parallelization / Blocking Analysis

```
T1: workflow-backend — CreateFeature endpoint + git-init + init_pr_url migration
  └── Can begin now — no blockers

  T2: digital-factory-ui — orchestrator type selector + init PR link in feature detail
      └── BLOCKED on T1 (needs init_pr_url in POST /features response and FeatureSummary type)

  T3: hermes-agent — document tools commit to init PR + owner-type branching + PR link button
      └── BLOCKED on T1 (needs init_pr_url in feature_state + init PR to exist on the branch)
```

T2 and T3 run in parallel once T1 merges.

## Repository Impact

| Repo | Changes |
|---|---|
| `workflow-backend` | New migration (`init_pr_url TEXT`); `CreateFeature` on `Service` + `WorkspaceService`; `CommitFiles` on `github.Client`; `InitPRURL *string` on `FeatureSummary`; one new route; embedded template strings |
| `digital-factory-ui` | Add `owner` to `CreateFeatureRequest`; add `init_pr_url` to `FeatureSummary`/`FeatureDetail` types; orchestrator type selector in `NewFeatureModal`; init PR link section in feature detail |
| `hermes-agent` | `write_product_spec` + `write_technical_design` updated to commit to init PR branch (with fallback create guard); owner-type guard on owner-dependent tools; PR link interactive button in chat response |

Repos not affected: `workflow`, `workflow-orchestrator`, `workflow-bff`, `workspace-github-adapter`, `rag-service`, `git-nexus`, `user-service`.

## Validation and Release Impact

### Testing expectations
- **workflow-backend**: Unit test for `CreateFeature` service with mocked `github.Client`. Unit test for `CommitFiles`. Handler test for `POST /features`. Existing tests must pass.
- **digital-factory-ui**: Component test for `NewFeatureModal` with owner selector. Smoke: create feature → init PR link appears.
- **hermes-agent**: Unit test for `write_product_spec` / `write_technical_design` with mock feature state (init_pr_url null path and non-null path). Owner-type guard tested for both `ts` and `go`.

### Migration / config impact
- One new migration: `init_pr_url TEXT` on `workspace_features`. Nullable, no default — backward compatible. Existing rows have `init_pr_url = NULL`; UI and Hermes handle null gracefully (no banner, no button).
- `owner` column already present (migration 00015). No further schema changes beyond `init_pr_url`.

### Rollout concerns
- Features created before this ships have `init_pr_url = NULL`. No backfill needed; the init PR link simply doesn't appear for old features.
- `owner = NULL` → `ts` default preserved for all existing records.

### Backward compatibility
- All existing read endpoints unchanged.
- Existing Hermes tools unchanged when `owner` is absent or `ts`.
- `start_stage` in the request body is ignored by the new endpoint (init always starts at `in_design`).
