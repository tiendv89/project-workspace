# Tasks — task-review (Task Review page — real task review experience)

> Feature status (reference): `in_tdd` → task planning. Stage `tasks`: awaiting approval.
> **Machine-mutable state (status, depends_on, branch, pr, log) lives in `tasks/T<n>.yaml`** —
> this file is narrative only. Source of truth for state is the YAML.

Design basis: `technical-design.md` (§4 chosen design, §6 parallelization, §7 repo impact).
5 tasks across 3 repos: **workflow-backend** (×2 — read-only GitHub PR diff + review-thread
endpoints), **workflow-bff** (×1 — proxy path-mapping), **digital-factory-ui** (×2 — data layer
+ view integration). v1 is **read-only**: no DB schema, no orchestrator, no task-lifecycle
changes; merge / request-changes actions are neutralized (deferred to a follow-up feature).

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | workflow-backend: PR files+diff GitHub client methods + task diff endpoint | — |
| T2 | 1 | workflow-backend: PR reviews+comments GitHub client methods + review-thread endpoint | — |
| T3 | 2 | workflow-bff: proxy path-mapping for the diff + review-thread routes | T1, T2 |
| T4 | 3 | digital-factory-ui: diff + review-thread service methods, types, and hooks | T1, T2, T3 |
| T5 | 4 | digital-factory-ui: wire task-review-view to real diff, thread, Spec tab + states | T4 |

---

## T1 — workflow-backend: PR files+diff GitHub client methods + task diff endpoint

### Description
Add read-only diff capability to the Go backend (design §4, Q1 → live-from-GitHub). Extend
`internal/github/client.go` with methods to fetch a PR's changed files and unified diff, and
expose a new Gin read endpoint that resolves a task to its PR and returns the diff.

- New GitHub client methods (read-only, reuse the existing service token + `httptest` test
  pattern via `newWithBaseURL`):
  - `GetPRFiles(ctx, owner, repo, prNumber)` → list of changed files with per-file
    `additions` / `deletions` / `status` / `filename` (GitHub `GET /repos/{o}/{r}/pulls/{n}/files`,
    paged).
  - `GetPRDiff(ctx, owner, repo, prNumber)` → unified diff text (GitHub
    `GET /repos/{o}/{r}/pulls/{n}` with `Accept: application/vnd.github.v3.diff`).
- New endpoint under the existing task route group:
  `GET /api/workspaces/:workspaceId/tasks/:taskId/diff?repo=<repo_id>`.
  - Resolve the task → select `pr` (default) or the PR for the requested `repo` (`workspace_pr`
    / multi-repo); parse `owner`/`repo`/`prNumber` from the PR ref URL.
  - Return the `{ success, data }` envelope with file list (real paths + per-file +/- counts) and
    diff hunks per file.
- Handle and test: no PR yet (return an explicit empty payload, not an error), not-found,
  unauthorized, and rate-limit responses.
- Optional: short server-side cache keyed by PR number + head SHA (best-effort; safe to omit).

### Required skills
- go-best-practices
- backend-engineer

### Subtasks
- [ ] Add `GetPRFiles` to `internal/github/client.go` (paged) with an `httptest` unit test.
- [ ] Add `GetPRDiff` (diff media type) with an `httptest` unit test.
- [ ] Add the `GET .../tasks/:taskId/diff` handler + route registration; resolve PR ref by `repo`.
- [ ] Define the response DTO (file list + per-file +/- counts + hunks) — freeze the shape for T3/T4.
- [ ] Handler tests: success, no-PR empty case, not-found, unauthorized, rate-limit.
- [ ] `golangci-lint run` clean; full Go test suite passes before PR.

## T2 — workflow-backend: PR reviews+comments GitHub client methods + review-thread endpoint

### Description
Add read-only review-thread capability to the Go backend (design §4, Q2 → merged thread). Extend
`internal/github/client.go` to fetch PR reviews and comments, and expose a read endpoint that
returns the PR-side review conversation for a task. The orchestrator verdict from `task.log` is
merged in by the FE (T5) — this task owns only the GitHub-sourced portion.

- New GitHub client methods (read-only, service token, `httptest` tests):
  - `GetPRReviews(ctx, owner, repo, prNumber)` → reviews with `state`
    (APPROVED / CHANGES_REQUESTED / COMMENTED), author, body, `submitted_at`
    (`GET /repos/{o}/{r}/pulls/{n}/reviews`).
  - `GetPRReviewComments(ctx, owner, repo, prNumber)` → inline/line comments with `path`,
    `line`, author, body, `created_at` (`GET /repos/{o}/{r}/pulls/{n}/comments`).
  - `GetIssueComments(ctx, owner, repo, prNumber)` → top-level PR conversation comments
    (`GET /repos/{o}/{r}/issues/{n}/comments`).
- New endpoint: `GET /api/workspaces/:workspaceId/tasks/:taskId/review-thread?repo=<repo_id>`.
  - Resolve PR ref the same way as T1; return a normalized `{ success, data }` payload with a
    single chronologically-orderable list (reviews + review comments + issue comments), each
    item carrying `kind`, `author`, `body`, `path?`, `line?`, `state?`, `created_at`.
- Handle and test the no-PR / not-found / unauthorized / rate-limit cases.

### Required skills
- go-best-practices
- backend-engineer

### Subtasks
- [ ] Add `GetPRReviews`, `GetPRReviewComments`, `GetIssueComments` with `httptest` unit tests.
- [ ] Add the `GET .../tasks/:taskId/review-thread` handler + route; resolve PR ref by `repo`.
- [ ] Define the normalized thread-item DTO — freeze the shape for T3/T4.
- [ ] Handler tests: success, no-PR empty case, not-found, unauthorized, rate-limit.
- [ ] `golangci-lint run` clean; full Go test suite passes before PR.

## T3 — workflow-bff: proxy path-mapping for the diff + review-thread routes

### Description
Make the two new backend routes reachable through the BFF (design §4 data flow, §1 BFF). The BFF
is a generic Go reverse proxy (`internal/app/api/handler/proxy/routing.go`) that maps incoming
`/bff/workflow-backend/...` paths to the `workflow-backend` upstream via a path-mapping table.
Add (or confirm) the path-mapping / allowlist entries for:

- `/bff/workflow-backend/api/workspaces/:workspaceId/tasks/:taskId/diff`
- `/bff/workflow-backend/api/workspaces/:workspaceId/tasks/:taskId/review-thread`

If the existing root-path proxy already admits arbitrary sub-paths under
`/bff/workflow-backend`, this task reduces to a routing-table test proving the two paths resolve
to the correct upstream — keep the change minimal and config-only; do not add bespoke handlers.

### Required skills
- go-best-practices
- backend-engineer

### Subtasks
- [ ] Determine whether the generic root-path proxy already forwards the two new paths.
- [ ] If an explicit mapping/allowlist is required, add the two entries (config, not code).
- [ ] Add/extend a routing-table test asserting both paths resolve to the `workflow-backend` upstream.
- [ ] `golangci-lint run` clean; full Go test suite passes before PR.

## T4 — digital-factory-ui: diff + review-thread service methods, types, and hooks

### Description
Add the frontend data layer for the two new endpoints (design §4 data flow, §6 wave 3). No UI
rendering here — only typed clients and hooks, so T5 can wire them in.

- Types mirroring the frozen backend DTOs (diff file list + hunks; normalized thread items) in
  `src/services/workflow-backend/types.ts` (or a sibling module).
- Service methods in `src/services/workflow-backend/*` using the existing `workflowApi`
  (BFF) client: `getTaskDiff(workspaceId, taskId, repo?)` and
  `getTaskReviewThread(workspaceId, taskId, repo?)`, unwrapping the `{ success, data }` envelope.
- React Query hooks (matching the repo's existing hook conventions under `src/hooks/`) keyed by
  workspace + task + repo, with loading / error surfaces consumable by the view.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add diff + thread response types matching T1/T2 DTOs.
- [ ] Add `getTaskDiff` and `getTaskReviewThread` service methods on `workflowApi`.
- [ ] Add React Query hooks (keyed by workspace/task/repo) with loading + error states.
- [ ] Unit tests for the service methods (envelope unwrap, repo param, error mapping).
- [ ] Lint clean; full test suite passes before PR.

## T5 — digital-factory-ui: wire task-review-view to real diff, thread, Spec tab + states

### Description
Replace the mock in `src/components/tasks/task-review-view.tsx` with real data (design §4, §6
wave 4). Single FE editor of this 361-LOC component to avoid parallel-edit conflicts. Preserve
the existing two-pane layout and theme tokens — change data and behavior only (product-spec
non-goal: no visual redesign).

- **Diff panel:** render the real file list (real paths + per-file/per-repo additions/deletions)
  and real diff hunks from the T4 diff hook; remove `PLACEHOLDER_DIFF` and the hardcoded filename;
  drive per-repo +/- counts from data. The existing repo-selector pills switch the active repo →
  pass `repo` to the diff/thread hooks.
- **Review thread:** render the merged thread — GitHub reviews/comments from the T4 hook +
  the orchestrator verdict from `task.log` (`reviewer_complete`, `review_blocked`, already in
  hand) — sorted chronologically; remove the hardcoded reviewer/inline comments and the static
  "✓ APPROVED" badge.
- **Spec tab:** render the task spec from data already present (`task.title`, `task.description`,
  `depends_on`, `status`); the tab no longer renders nothing.
- **States:** honest loading / empty / error / no-PR states per existing page conventions — never
  fabricated content.
- **Actions:** neutralize "Merge PR" / "Request changes" — remove or disable with a clear note
  ("managed by the review workflow"; optionally link out to the PR). They must not appear
  actionable while doing nothing (product-spec non-goal). Governed write actions are a follow-up.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Wire the diff panel to the T4 diff hook (real files, hunks, +/- counts); drop `PLACEHOLDER_DIFF`.
- [ ] Make the repo-selector pills drive the `repo` param into the diff + thread hooks.
- [ ] Wire the review thread to the T4 thread hook + merge `task.log` verdict, sorted by time.
- [ ] Implement the Spec tab from existing task fields.
- [ ] Add loading / empty / error / no-PR states matching page conventions.
- [ ] Neutralize Merge / Request-changes buttons (disable/remove + clear note).
- [ ] Component/unit tests for diff, thread ordering, Spec tab, and each state; lint + full suite green before PR.
