# Tasks - Check Status Across All Branches

**Feature status:** [`status.yaml`](status.yaml) - revised task breakdown awaiting human approval after the product spec and technical design changed.
**Machine state:** [`tasks/T<n>.yaml`](tasks/) - source of truth for status, dependencies, branch, PR, and log.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | GitHub snapshot loader and YAML parsing | - |
| T2 | 2 | Feature list and detail APIs | T1 |
| T3 | 3 | Dashboard API data migration | T2 |
| T4 | 1 | GitHub webhook verification and task file detection | - |
| T5 | 2 | SSE event bus and client sync hook | T4 |
| T6 | 3 | Rollback and stale-state guards | T1, T4, T5 |
| T7 | 4 | Verification and operational documentation | T2, T3, T4, T5, T6 |

---

## T1 - GitHub snapshot loader and YAML parsing

### Description

Build the shared GitHub archive reader for `Kadamato/project-workspace` so the dashboard can load workflow state from the `main` codeload ZIP instead of local files. This task owns ZIP download, dynamic archive-root detection, file listing, YAML parsing helpers, feature/task path matching, and focused unit coverage.

This task is the base for both feature APIs and rollback reads because those flows need the same trusted `main` snapshot loader.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `src/lib/github/archive.ts` to download `https://codeload.github.com/Kadamato/project-workspace/zip/refs/heads/main`.
- [ ] Parse ZIP content with `JSZip` and derive the generated root folder dynamically instead of hardcoding `project-workspace-main/`.
- [ ] Add helpers to list archive files, read text content, and normalize paths relative to the archive root.
- [ ] Add YAML parsing helpers using `yaml` that return parsed data plus parse errors without crashing the whole snapshot.
- [ ] Add path matchers for `docs/features/*/status.yaml` and `docs/features/<featureId>/tasks/T*.ya?ml`.
- [ ] Add safe `featureId` validation with `^[A-Za-z0-9._-]+$`.
- [ ] Add unit tests for archive-root detection, status file selection, task file selection, invalid YAML handling, and unsafe feature IDs.

---

## T2 - Feature list and detail APIs

### Description

Expose the GitHub snapshot loader through Next.js API routes. The feature list route returns every `status.yaml` as one feature record. The feature detail route returns one feature's `status.yaml` plus matching `tasks/T*.yaml` records whose `branch` starts with `feature/<featureId>-T`.

This task defines the server response contracts that the UI migration consumes.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `GET /api/github/features` as a dynamic route that loads the GitHub `main` ZIP snapshot.
- [ ] Return `repo`, `ref`, `count`, and `files` records with `featureId`, `path`, raw `content`, parsed `status`, and optional `parseError`.
- [ ] Ensure one invalid `status.yaml` does not fail the full feature list response.
- [ ] Add `GET /api/github/features/[featureId]` with feature ID validation.
- [ ] Load `docs/features/<featureId>/status.yaml` and return `404` when it does not exist.
- [ ] Scan `docs/features/<featureId>/tasks/T*.yaml` and `T*.yml`.
- [ ] Include only tasks whose parsed `branch` starts with `feature/<featureId>-T`.
- [ ] Return task records with `path`, `id`, `title`, `status`, `branch`, raw `content`, and parsed YAML.
- [ ] Sort task records by numeric task ID.
- [ ] Add route tests with mocked ZIP archives for list success, detail success, invalid YAML, missing feature, and unsafe feature IDs.

---

## T3 - Dashboard API data migration

### Description

Move dashboard feature list and feature detail views away from local filesystem readers and onto the new GitHub-backed API responses. The UI should render the same workflow concepts, but its read source becomes the API response instead of `docs/features/**` on disk.

This task should preserve the existing visual model while changing the data boundary.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices
- browser-qa-frontend

### Subtasks
- [ ] Identify existing local feature/task readers used by the dashboard views.
- [ ] Replace feature list loading with `GET /api/github/features`.
- [ ] Replace feature detail loading with `GET /api/github/features/[featureId]`.
- [ ] Map API response fields into the existing UI data model or introduce a small adapter layer.
- [ ] Show parse errors or missing task data as per-record degraded state instead of breaking the whole page.
- [ ] Ensure feature detail state can be passed into the later `useGitHubSync` hook as initial task records.
- [ ] Remove or isolate local filesystem reads from the dashboard paths covered by this feature.
- [ ] Run browser smoke checks for feature list and feature detail rendering.

---

## T4 - GitHub webhook verification and task file detection

### Description

Add the Next.js webhook route that receives GitHub events securely. This task owns raw body reading, HMAC SHA-256 verification with `GH_SECRET`, event type dispatch, pull request changed-file lookup, task YAML path detection, and idempotency keys.

This task does not need the SSE route to be done; it can return structured internal events or call a temporary publisher interface that T5 completes.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `POST /api/webhooks/github` with `runtime = "nodejs"` and `dynamic = "force-dynamic"`.
- [ ] Read the raw body with `await request.arrayBuffer()` before JSON parsing.
- [ ] Validate `x-hub-signature-256` using `GH_SECRET`, HMAC SHA-256, length check, and `crypto.timingSafeEqual`.
- [ ] Return `401` for missing, malformed, or mismatched signatures.
- [ ] Handle `ping`, `pull_request`, and `delete` GitHub events.
- [ ] Fetch PR changed files from `GET /repos/:owner/:repo/pulls/:pull_number/files`, using `GITHUB_TOKEN` when configured.
- [ ] Parse task file paths matching `docs/features/<featureId>/tasks/T*.ya?ml`.
- [ ] Derive `featureId`, `taskId`, PR head ref, PR head SHA, and PR metadata for each affected task.
- [ ] Add duplicate-delivery protection keyed by delivery ID, event name, action, task path, and head SHA.
- [ ] Add tests for signature verification, safe length mismatch handling, event filtering, task path parsing, and duplicate delivery.

---

## T5 - SSE event bus and client sync hook

### Description

Implement the background status update channel. The server exposes `/events` as an SSE stream and the client uses `EventSource` to update visible task records by `branch`, `featureId`, and `taskId`.

This task connects the webhook event producer to browser consumers without adding a separate Express server or custom reconnect loop.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `src/lib/github/task-status-events.ts` with an in-memory subscriber registry for a single long-running Next.js process.
- [ ] Define the `TaskStatusEvent` payload with `type`, `featureId`, `taskId`, `branch`, `status`, `source`, delivery metadata, and PR metadata.
- [ ] Add `GET /events` using a streaming `ReadableStream` compatible with browser `EventSource`.
- [ ] Send initial keepalive/comment frames so idle connections stay open where supported.
- [ ] Add publisher functions for webhook code to broadcast task status updates.
- [ ] Add `src/hooks/use-github-sync.ts` that accepts initial tasks and updates matching tasks from `EventSource("/events")`.
- [ ] Rely on native browser reconnect behavior; do not add custom reconnect timers.
- [ ] Integrate the hook into the feature detail task list.
- [ ] Add tests for event publish/subscribe behavior and client task-state update matching.

---

## T6 - Rollback and stale-state guards

### Description

Handle the edge cases that prevent the UI from displaying stale success. PR close without merge, PR merge, branch delete, invalid PR-head YAML, missing files, deleted files, and renamed files must all reconcile back to the latest trusted `main` snapshot or mark the snapshot invalid when rollback cannot be completed.

This task is intentionally separate because stale `done` state is the highest-risk behavior in this feature.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Fetch and parse task YAML from the PR head SHA for active PR actions.
- [ ] On `pull_request.closed` with `merged: false`, reload the affected task from the latest `main` snapshot and broadcast `task_status_rollback`.
- [ ] On `pull_request.closed` with `merged: true`, retry/backoff before loading from `main` to avoid codeload eventual consistency.
- [ ] On branch `delete` events matching `feature/<featureId>-T<n>`, reload the task from `main` and broadcast rollback.
- [ ] Fallback to the latest `main` snapshot when PR-head task YAML is invalid, missing, removed, or renamed.
- [ ] Broadcast `task_snapshot_invalidated` when neither PR-head YAML nor `main` snapshot can provide a trusted status.
- [ ] Enforce that PR state alone never maps to `status: done`.
- [ ] Add tests for PR close without merge, PR merged retry, branch delete, invalid YAML fallback, missing task fallback, renamed/deleted task files, and stale `done` prevention.

---

## T7 - Verification and operational documentation

### Description

Finish the feature with end-to-end verification and operator documentation. This includes API route tests, webhook fixture tests, browser smoke coverage, environment configuration notes, webhook setup notes, and the production caveat that in-memory SSE requires a single long-running process or a shared pub/sub backend.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices
- browser-qa-frontend

### Subtasks
- [ ] Add or update integration tests covering `GET /api/github/features`.
- [ ] Add or update integration tests covering `GET /api/github/features/[featureId]`.
- [ ] Add signed webhook fixtures for PR open/synchronize, PR close without merge, PR merge, and branch delete.
- [ ] Verify duplicate webhook delivery returns `200` and does not rebroadcast.
- [ ] Run `pnpm lint`, `pnpm build`, and the repo's available test command.
- [ ] Run browser smoke coverage for feature list, feature detail, SSE task update, and rollback state.
- [ ] Document required environment variables: `GITHUB_OWNER`, `GITHUB_REPO`, `GITHUB_REF`, `GH_SECRET`, and optional `GITHUB_TOKEN`.
- [ ] Document GitHub webhook setup, event subscriptions, signature verification, and local testing flow.
- [ ] Document the production SSE scaling caveat and shared pub/sub follow-up path.
