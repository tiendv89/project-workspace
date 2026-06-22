# Tasks — feature-initialization-compatible

Feature status: `in_tdd` | Tasks stage: `draft` | Machine state lives in `tasks/T<n>.yaml`

## Index

| ID  | Wave | Title                                              | Depends on |
|-----|------|----------------------------------------------------|------------|
| T1  | 1    | workflow-backend: CreateFeature endpoint + git-init | —          |
| T2  | 2    | digital-factory-ui: orchestrator selector + init PR UI | T1      |
| T3  | 2    | hermes-agent: document tools commit to init PR + owner awareness | T1 |

---

## T1 — workflow-backend: CreateFeature endpoint + git-init

### Description
Implement the `POST /api/workspaces/:workspaceId/features` endpoint in workflow-backend. This is the foundation for the entire feature — T2 and T3 both depend on the fields this endpoint populates.

Concretely:

1. **DB migration** — add `init_pr_url TEXT` and `init_pr_merged BOOLEAN NOT NULL DEFAULT FALSE` to `workspace_features`. (`owner` already exists from migration 00015.)

2. **`CommitFiles` on `github.Client`** — add `CommitFiles(ctx context.Context, owner, repo, branch, baseBranch, message string, files map[string]string) error` using the GitHub Git Data API (create blobs → create tree → create commit → update ref). This produces a single atomic commit for all template files instead of N sequential `PutFileContent` calls.

3. **Embedded template strings** — embed the ts-variant and go-variant template file sets as Go string constants. ts-variant includes `tasks/.gitkeep`; go-variant includes `owner: go` in `status.yaml` and omits `tasks/.gitkeep`.

4. **`CreateFeature` service method** — implement `CreateFeature(ctx, workspaceID, input CreateFeatureInput) (*FeatureSummary, SourceError)` in `WorkspaceService`:
   - Validate: `name` required, `owner` must be `"ts"` or `"go"` (or empty → `"ts"`).
   - Insert `workspace_features` row (`feature_id` as new UUID, `owner` set, `init_pr_url` and `init_pr_merged` initially null/false).
   - Derive management repo owner/name from `githubRepoURL`.
   - Call `CommitFiles` to create branch `feature/<feature_id>-init` from `main` and commit the appropriate template set.
   - Call `EnsurePR` to open the init PR (`feature/<feature_id>-init` → `main`).
   - Update `init_pr_url` in DB with the returned PR HTML URL.
   - Return populated `FeatureSummary`.

5. **Lazy `init_pr_merged` check** — in `GetFeature`, if `init_pr_url` is non-null and `init_pr_merged = false`, call `GET /repos/{owner}/{repo}/pulls` filtered by `head = feature/<id>-init` and check `merged_at`. If merged, write `init_pr_merged = true` to DB before returning the response.

6. **`CreateFeature` handler** — register `POST /workspaces/:workspaceId/features` in `RegisterRoutes`; bind JSON body to `CreateFeatureInput`; call service; respond 201.

7. **DTO update** — add `InitPRURL *string json:"init_pr_url,omitempty"` and `InitPRMerged bool json:"init_pr_merged"` to `FeatureSummary`.

### Required skills
- backend-engineer
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Write and run migration (init_pr_url TEXT, init_pr_merged BOOLEAN DEFAULT FALSE)
- [ ] Add `CommitFiles` to `github.Client` using Git Data API; unit test with httptest stub
- [ ] Embed ts and go template file sets as Go string constants
- [ ] Implement `CreateFeature` on `Service` interface and `WorkspaceService`
- [ ] Implement lazy `init_pr_merged` check in `GetFeature`
- [ ] Add `InitPRURL *string` and `InitPRMerged bool` to `FeatureSummary` DTO
- [ ] Register `POST /workspaces/:workspaceId/features` handler route
- [ ] Unit tests: `CreateFeature` with mocked `github.Client` (happy path, GitHub failure, duplicate name)
- [ ] Unit test: lazy `init_pr_merged` flip on `GetFeature`
- [ ] Run full test suite — all pass before PR

---

## T2 — digital-factory-ui: orchestrator selector + init PR UI

### Description
Update the frontend to support the new feature creation flow and surface the init PR state.

1. **Types** — add `owner?: "ts" | "go"` to `CreateFeatureRequest`; add `init_pr_url?: string` and `init_pr_merged: boolean` to `FeatureSummary` and `FeatureDetail`.

2. **`NewFeatureModal` — orchestrator type selector** — add a radio/select for "TypeScript / Git" (default) vs "Postgres / Go" below the name field. Pass the selected `owner` in the `createFeature` API call. Remove `start_stage` from the payload (backend ignores it; init always starts at `in_design`).

3. **Init PR banner** — in the feature detail header (or `FeatureWorkbench`), when `init_pr_url` is non-null, show a small banner: "View Init PR" link (opens `init_pr_url` in a new tab). No API call needed.

4. **Document tab status tags** — in `FeatureIDEDocsPanel`, add a status badge next to each document tab label:
   - `init_pr_url` null → no badge
   - `init_pr_url` set + `init_pr_merged = false` → amber **"in PR"** badge
   - `init_pr_url` set + `init_pr_merged = true` → green **"verified"** badge
   The badge applies to all document tabs (product_spec, technical_design) simultaneously since they share the same init PR.

5. **Auto-switch right panel tab** — when a `workflow_write_product_spec` or `workflow_write_technical_design` tool card (`DocumentEditCard`) appears in the chat, the right panel (`FeatureIDEDocsPanel`) auto-selects the corresponding document tab. Extend the existing artifact-save invalidation in `FeatureWorkbench` (lines 312–325) to also emit the active document type signal.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices

### Subtasks
- [ ] Add `owner`, `init_pr_url`, `init_pr_merged` to `CreateFeatureRequest`, `FeatureSummary`, `FeatureDetail` types
- [ ] Add orchestrator type selector (radio or select) to `NewFeatureModal`; pass `owner` in API call; remove `start_stage`
- [ ] Add init PR banner to feature detail / workbench header when `init_pr_url` non-null
- [ ] Add "in PR" / "verified" badge to document tab labels in `FeatureIDEDocsPanel`
- [ ] Auto-switch right panel tab on `DocumentEditCard` appearance in chat
- [ ] Handle `init_pr_url = null` gracefully everywhere (no banner, no badge)
- [ ] Component test: `NewFeatureModal` with orchestrator selector renders and submits correctly
- [ ] Component test: `FeatureIDEDocsPanel` shows correct badge for each init_pr state
- [ ] Run full test suite — all pass before PR

---

## T3 — hermes-agent: document tools commit to init PR + owner awareness

### Description
Update Hermes so that document write tools commit to the correct branch based on init PR state, and so owner-dependent operations branch correctly for `ts` vs `go` features.

1. **`write_product_spec` and `write_technical_design` branch logic** — after writing content, determine the target branch:
   - `init_pr_url` non-null + branch `feature/<id>-init` exists on GitHub → commit to init PR branch.
   - `init_pr_url` non-null + branch gone (PR merged) → commit to `feature/<id>` branch (create from `main` if absent).
   - `init_pr_url` null (pre-existing feature) → commit to `feature/<id>` branch directly; do not create an init PR.

2. **PR link interactive button** — after a successful document commit, return the target PR/branch URL as a clickable button in the chat response. The `DocumentEditCard` component in the UI already renders this from the tool output.

3. **Owner-type guard** — before any owner-dependent operation (write task YAML files, create task-state git branches), read `feature_state["owner"]`. If `owner == "go"`, skip the operation and return a descriptive message. If `owner == "ts"` or absent, existing behaviour unchanged.

4. **`request_approval` call after document write** — after committing the document, call `request_approval(stage: <product_spec|technical_design>)` so the approve button appears in the feature detail view.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Update `write_product_spec` to check init PR branch existence and commit to correct branch
- [ ] Update `write_technical_design` with the same branch logic
- [ ] Add `request_approval` call at end of each document write tool
- [ ] Return PR/branch URL as interactive button in chat response
- [ ] Add owner-type guard to owner-dependent tools (task YAML write, task branch creation)
- [ ] Test branch-decision logic: init PR open, init PR merged, no init PR (null)
- [ ] Test owner guard: `ts` feature proceeds, `go` feature skips and returns descriptive message
- [ ] Run full test suite — all pass before PR
