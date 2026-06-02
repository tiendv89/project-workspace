# Tasks — m1-fix-import-no-organization

> Feature status: `in_tdd` (reference). Stage status: `tasks/draft` until human approval.
> Machine-mutable state for each task lives in `tasks/T<n>.yaml`. This file is narrative
> only — descriptions, required skills, and subtask checklists.
>
> Recreated `2026-06-01T18:32:46+0700` after the technical design's request-body
> example was corrected (placeholder UUID → `slug='kitelabs'`-sourced guidance).
> Task scope is unchanged from the pre-revision draft; this is a clean re-author.

## Index

| ID | Wave | Title | Repo | Depends on |
|---|---|---|---|---|
| T1 | 1 | Wire `organization_id` end-to-end in workspace-github-adapter import path | workspace-github-adapter | — |
| T2 | 2 | Cross-service verification — `workflow-backend` round-trips `organization_id` | workflow-backend | T1 |

## T1 — Wire `organization_id` end-to-end in workspace-github-adapter import path

### Description

The break identified in the technical design lives entirely in
`workspace-github-adapter`: the `importWorkspaceRequest` JSON struct drops
`organization_id` at decode, the sqlc `UpsertWorkspaceByID` query has no
`organization_id` column, and the in-tx placeholder writer does not pass one.
This task wires the field end-to-end inside that one repo so the workspace
INSERT carries a valid `organization_id` on every import, the request is
rejected loudly when the field is missing or malformed, and the on-conflict
path preserves existing ownership.

Scope and acceptance criteria are exactly the §Chosen Design section of the
technical design — strict validation at the decode boundary (Option 3B) and
ON CONFLICT preservation of `organization_id` (Option 2B).

The literal `organization_id` value supplied at runtime is whatever UUID
`user-service`'s seed assigned to `organizations.slug='kitelabs'` (see
`user-service/cmd/seed/seed.go::seedKitelabsOrg`). This task does not depend
on knowing that UUID statically — `workflow-backend` injects it into
`AuthCtx.OrganizationID` from the session payload, and the adapter receives
it on the wire.

This task does **not** change any schema migration; `workflow_db` already
carries `workspaces.organization_id` from `m1-identity-and-workspaces`
migrations `00013` and `00014`.

### Required skills

- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Add `OrganizationID string \`json:"organization_id"\`` to `importWorkspaceRequest` in `internal/handler/import.go`
- [ ] Validate `OrganizationID` after `RepoURL`: empty string → 400 `ValidationMissingInput` ("organization_id is required"); malformed UUID → 400 `ValidationInvalidInput` ("organization_id must be a UUID"); zero UUID (`00000000-...`) → 400 `ValidationInvalidInput` ("organization_id must not be the zero UUID")
- [ ] Update `database/queries/workspaces.sql`:
  - `UpsertWorkspaceByID`: add `organization_id` to the INSERT column list; do **not** update `organization_id` in the `ON CONFLICT (id) DO UPDATE` clause; add `organization_id` to the RETURNING list
  - `UpsertWorkspace` (by slug): apply the same change for symmetry, even though no live caller invokes it today
- [ ] Run `sqlc generate`; verify `internal/database/workspaces.sql.go` regenerates so that `UpsertWorkspaceByIDParams`, `UpsertWorkspaceParams`, and the `Workspace` row struct each gain `OrganizationID pgtype.UUID`
- [ ] Update `createImportPlaceholder` / `createImportPlaceholderWithQueries` in `internal/handler/import.go` to accept an `organizationID string`, parse it to `pgtype.UUID`, and set it on `UpsertWorkspaceByIDParams`
- [ ] Plumb the value through from `ImportWorkspaceHandler` so the handler-validated UUID is what reaches `createImportPlaceholder`
- [ ] Add `"organization_id"` to the 200 / 202 response body for the success and `already_queued` branches (additive — existing keys preserved)
- [ ] Update existing tests in `internal/handler/webhook_handler_test.go` (`TestImportWorkspaceHandler_GitHubNotFoundDoesNotPersistPlaceholder`, `TestImportWorkspaceHandler_DifferentRepoWithExistingSlugReturnsConflict`, plus any sibling tests) to send `organization_id` in the request bodies
- [ ] Add new handler-level unit tests covering: happy path with a valid UUID; missing field; empty string; zero UUID; malformed UUID — each negative branch must assert no `workspaces` row is written and no async sync task is enqueued
- [ ] Add an adapter-level DB / integration test that re-imports the same workspace `id` with a *different* `organization_id` and asserts the row's `organization_id` is **unchanged** (validates the Option 2B conflict semantics)
- [ ] Run the full test suite and `golangci-lint run` — both must be green before pushing

## T2 — Cross-service verification — `workflow-backend` round-trips `organization_id`

### Description

`workflow-backend` already wires the session's `OrganizationID` from
`authmw.AuthCtx` into `ImportInput.OrganizationID` and forwards it via
`adapter.ImportRequest`. This task adds defence-in-depth tests in
`workflow-backend` so that a regression silently dropping the field in transit
would be caught at CI time — without touching production code.

This task lands **after** T1 is merged because the adapter's accepted
contract (request body + response) is part of what these tests exercise. We
do not want to land tests asserting a contract the adapter does not yet
honour.

### Required skills

- go-best-practices

### Subtasks

- [ ] Add an `rpc_test.go` case (`internal/adapter/rpc_test.go`) that captures the outgoing HTTP request body of `Client.ImportWorkspace`, decodes it, and asserts `"organization_id"` is present and matches the value supplied in `ImportRequest`
- [ ] Confirm or extend the existing handler test in `internal/handler/workspace_test.go` that proves the auth-context `OrganizationID` overwrites any body-supplied `organization_id` (test currently exists at the `authmw.FromContext` injection point — verify it stays green and assert end-to-end that the value reaching the adapter client is the session value)
- [ ] If no such handler test exists, add one: build a request with body `organization_id: "client-supplied"`, inject an `AuthCtx{OrganizationID: "session-org"}` via `authmw.SetAuthCtx`, capture the `adapter.ImportRequest` passed into the service layer, and assert it carries `"session-org"`
- [ ] Run the full test suite and `golangci-lint run` — both must be green before pushing
