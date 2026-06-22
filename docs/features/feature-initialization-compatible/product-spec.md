# Product Specification

## Feature
- Feature ID: `feature-initialization-compatible`
- Title: Feature Initialization — End-to-End Compatible Flow

## Problem

Creating a new feature via the UI (`POST /api/workspaces/:workspaceId/features`) is a no-op today. The endpoint is not implemented in workflow-backend, so the frontend call returns an error and the feature never materializes in git or the database.

Beyond the missing endpoint, the initialization flow is also incomplete in three other dimensions:

1. **No orchestrator type selection.** The UI form has no way to choose between the TypeScript/git model (task state in YAML files) and the Go/Postgres model (task state in the database). The choice matters because it determines what git artifacts get created and how Hermes behaves for that feature.

2. **No git initialization for TypeScript/git features.** When a `ts` feature is created, the management repo should receive a new branch and a PR containing the initial scaffolding (product-spec, technical-design, status.yaml, tasks/ and handoffs/ directories). This PR is the durable starting point agents and humans use to begin work. Without it, there is no branch, no files, and no way for the runtime to operate.

3. **No merge-PR affordance.** Once the init PR exists, there is no button in the UI or tool in Hermes to merge it. Users must leave the app and go to GitHub, which breaks the intended single-surface workflow.

## Goals

- Implement `POST /api/workspaces/:workspaceId/features` in workflow-backend so creating a feature is real and durable.
- Add an orchestrator type selector (TypeScript/Git | Postgres/Go) to the Create Feature modal in the UI.
- For TypeScript/git features: create a feature branch, commit all template files, and open a PR (`feature/<feature_id>-init` → `main`) on the management repo automatically on feature creation.
- For Postgres/Go features: create the feature record in the database and commit only the narrative files (product-spec.md, technical-design.md, status.yaml with `owner: go`) — no tasks/ directory.
- Store the init PR URL in the feature record so the UI and Hermes can surface it.
- Make Hermes owner-type aware: operations that differ between `ts` and `go` (branch creation, task file writes, task-state reads) must branch on `status.yaml`'s `owner` field.
- Add a "Merge Init PR" interactive button in the UI feature detail view and a corresponding Hermes tool call so users can merge the init PR without leaving the app.

## Non-goals

- Changing the technical-design, task-breakdown, or approval flows — this feature only covers the initialization step.
- Implementing the Postgres/Go task-state materialization path (that is handled separately by the `workflow-db` feature). This feature creates the DB record and narrative files; the orchestrator handles the rest.
- Migrating existing features retroactively. Only net-new features created after this feature ships go through the new init flow.
- Auto-merging the init PR. The merge is always user-initiated (via button or Hermes tool call).

## User Stories

### US-1 — Create a TypeScript/git feature from the UI
As a product owner, when I click "Create Feature" and fill in the name and description, I can select "TypeScript / Git" as the orchestrator type. After I confirm, the app creates the feature in the database, opens a PR on the management repo with the initial scaffold, and shows me the PR link immediately in the feature detail view.

### US-2 — Create a Postgres/Go feature from the UI
As a product owner, when I select "Postgres / Go" as the orchestrator type, the app creates the feature record in the database and commits the narrative files to a git branch — but does not create a tasks/ directory or task YAML files. The feature is immediately visible in the workspace board.

### US-3 — Merge the init PR from the UI
As a product owner, on the feature detail view I see a "Merge Init PR" button while the init PR is open. Clicking it merges the PR on GitHub and updates the feature record in the database to reflect that initialization is complete.

### US-4 — Hermes behaves correctly for each owner type
As a user, when I ask Hermes to perform any owner-dependent action (write task files, read task state, create branches), Hermes reads `status.yaml`'s `owner` field first and follows the correct path — never writing task YAML files for `go` features or skipping git operations for `ts` features.

## Key Flows

### TypeScript/Git creation flow
```
User submits form (name, description, owner=ts)
  → POST /api/workspaces/:workspaceId/features {name, description, owner: "ts"}
  → workflow-backend creates DB record (feature_status: in_design)
  → workflow-backend triggers git-init job:
       git checkout -b feature/<feature_id>-init main
       commit template files (product-spec.md, technical-design.md, status.yaml, tasks/.gitkeep, handoffs/.gitkeep)
       push branch to origin
       open PR: feature/<feature_id>-init → main
       store PR URL in DB
  → 201 response includes feature record + init_pr.url
  → UI navigates to feature detail, displays PR link + "Merge Init PR" button
```

### Postgres/Go creation flow
```
User submits form (name, description, owner=go)
  → POST /api/workspaces/:workspaceId/features {name, description, owner: "go"}
  → workflow-backend creates DB record (feature_status: in_design, owner: go)
  → workflow-backend triggers git-init job:
       git checkout -b feature/<feature_id>-init main
       commit narrative files only (product-spec.md, technical-design.md, status.yaml with owner: go)
       push branch + open PR
       store PR URL in DB
  → 201 response includes feature record + init_pr.url
  → UI navigates to feature detail
```

### Merge Init PR flow
```
User clicks "Merge Init PR" (UI button) OR Hermes calls merge_init_pr tool
  → POST /api/workspaces/:workspaceId/features/:featureId/merge-init-pr
  → workflow-backend calls GitHub API to merge the PR
  → updates DB record: init_pr.status = merged
  → returns updated feature record
  → UI hides "Merge Init PR" button, shows "Initialized" badge
```

## Acceptance Criteria

1. `POST /api/workspaces/:workspaceId/features` returns 201 with the created feature record and `init_pr.url` for both owner types.
2. For `ts` features: the management repo contains `feature/<feature_id>-init` branch with all template files committed; a PR targeting `main` is open on GitHub.
3. For `go` features: the management repo branch contains only narrative files; no `tasks/` directory or task YAML files are present.
4. The Create Feature modal in digital-factory-ui includes an orchestrator type selector with two options and passes the selection in the API request.
5. The feature detail view shows the init PR URL and a "Merge Init PR" button while `init_pr.status = open`.
6. Clicking "Merge Init PR" merges the PR on GitHub and hides the button in the UI.
7. Hermes renders an interactive "Merge Init PR" button in its response when an open init PR is present.
8. Hermes reads `owner` from `status.yaml` before any owner-dependent operation and follows the correct branch (ts vs go) without error.
9. All existing workspace and feature read endpoints continue to work unchanged.
