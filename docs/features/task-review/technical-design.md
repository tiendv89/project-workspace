# Technical Design

## Feature
- Feature ID: `task-review`
- Title: Task Review page — real task review experience

> Phase 1 design draft. Resolves the four open questions raised in the product
> spec into a concrete, additive design. The task decomposition below (T1–T5) is
> the **plan**; the formal `tasks.md` + `tasks/T<n>.yaml` are produced in Phase 2
> after this design is approved.

---

## 1. Current state

### Frontend (`digital-factory-ui`, Next.js 16 / React 19)
- Route `src/app/(shell)/task/[taskId]/page.tsx` resolves a task from
  `useWorkspaceContext().activeWorkspace.tasks` by `taskId` and renders
  `<TaskReviewView task={task} />` with loading / error / not-found handling.
- `src/components/tasks/task-review-view.tsx` (361 LOC) binds real task fields
  (id, title, status, branch, `pr`/`workspace_pr` refs) but the review content is
  **mocked**:
  - diff panel renders a hardcoded `PLACEHOLDER_DIFF` against a hardcoded filename
    (`src/routes/sessions.ts`); per-repo additions/deletions are always `0`;
  - the "Spec" tab renders nothing;
  - the entire **Review Thread** (reviewer comment, inline comment, "✓ APPROVED"
    badge) is hardcoded prose;
  - "Merge PR" and "Request changes" buttons have no handlers.
- API access: clients in `src/services/workflow-backend/*` call the BFF at
  `/bff/workflow-backend/...` (`src/constants/axios.ts`, `workflowApi`). The
  base URL is resolved per-request from server-provided runtime config.
- Available task-data endpoints today: workspace/feature/task listing, single task
  (`GetWorkspaceTask`), and feature **document** content (product spec / technical
  design / handoff). There is **no** diff, review-thread, or merge endpoint.

### BFF (`workflow-bff`, Go)
- Generic reverse proxy. `internal/app/api/handler/proxy/routing.go` builds a
  routing table from configured upstreams (`bff_root_path` → upstream host, with a
  per-upstream **path-mapping** table). New backend routes under the
  `workflow-backend` root path are reachable through the BFF once the path mapping
  / allowlist admits them — typically a **config change, not code**.

### Backend (`workflow-backend`, Go / Gin + Postgres)
- Serves tasks from the domain layer; tasks carry `pr` / `workspace_pr` refs
  (`repo`, `url`, `status`).
- `internal/github/client.go` is a GitHub REST client that can: `GetFileContent`,
  `ListPRsForBranch`, `EnsureBranch`, and create PRs. It uses a single
  service-level GitHub token (already used for document read/write + PR ops).
- It **cannot** today: fetch a PR's changed files / diff, fetch PR reviews, or
  fetch review/issue comments. There is no merge call.

### Constraints / limitations
- One backend GitHub token (service identity), 15s HTTP timeout, `per_page` paging.
- GitHub API rate limits apply to live reads.
- Workspace governance: task lifecycle transitions and PR merges are owned by the
  **orchestrator / human review boundary** (see `CLAUDE.md` — "Review boundary",
  "Branch merge rule", `handleMergedPrs`). The UI must not silently bypass that.

---

## 2. Problem framing

### What must change
Replace the mocked review experience on `/task/{taskId}` with real, data-backed
content: the actual PR diff(s), the actual review thread/verdict, and a populated
Spec tab — with honest empty/loading/error states.

### What must remain stable
- The page's visual layout, theme tokens, and component structure (two-pane:
  diff left, review thread right). This feature changes **data and behavior**,
  not the look (product-spec non-goal).
- The task lifecycle, reviewer-dispatch semantics, and orchestrator merge
  ownership. The page **reflects** review state; it does not redefine it.
- The existing FE→BFF→backend contract style (REST under `/bff/workflow-backend`,
  `{ success, data }` envelope).

### Fixed assumptions
- Reads use the existing backend service GitHub token (see §4, Q4).
- Tasks already expose `pr` / `workspace_pr` refs from which owner/repo/PR-number
  are derivable.
- v1 is **read-only** with respect to GitHub and task state (see §4, Q3).

---

## 3. Options considered

### Q1 — Diff source

**Option A — Live from GitHub via a new read-only backend endpoint (CHOSEN).**
Backend adds GitHub client methods (`GET /repos/{o}/{r}/pulls/{n}/files`, and the
unified diff via `Accept: application/vnd.github.v3.diff`) behind a new read
endpoint; FE fetches on page load.
- Pros: always current; reuses the existing GitHub read client + token; no schema
  or orchestrator changes; purely additive.
- Cons: a GitHub round-trip per view; subject to rate limits (mitigate with a
  short server-side cache keyed by PR number + head SHA).
- Impact: backend client + endpoint; no DB.

**Option B — Persist diff metadata when the orchestrator opens/updates a PR.**
- Pros: fast reads; no GitHub call on view.
- Cons: new orchestrator write path + storage/schema; staleness between PR pushes
  and persistence; larger blast radius across repos. Rejected for v1.

### Q2 — Review-thread source

**Option A — GitHub PR reviews + comments only.**
- Pros: shows the real PR conversation.
- Cons: misses the orchestrator's own reviewer verdict when it lives only in the
  task log; thread looks empty for tasks reviewed by the agent before any GitHub
  review is posted.

**Option B — Orchestrator reviewer verdict (task `log`) only.**
- Pros: no new backend call; FE already has `task.log`.
- Cons: omits human PR comments and GitHub-side review state.

**Option C — Merge both into one chronological thread (CHOSEN).**
Primary source = GitHub PR **reviews** (`GET /pulls/{n}/reviews`), **review
comments** (`GET /pulls/{n}/comments`), and **issue comments**
(`GET /issues/{n}/comments`) via a new read endpoint. Overlay the orchestrator
verdict already present in `task.log` (`reviewer_complete`, `review_blocked`)
which the FE has in hand.
- Pros: faithful and complete; honest about both agent and human review activity.
- Cons: FE must merge/sort two streams by timestamp. Acceptable.

### Q3 — Merge / Request-changes actions

**Option A — Ship v1 read-only; neutralize the action buttons (CHOSEN).**
Remove or disable the "Merge PR" / "Request changes" buttons, with a clear inline
note ("managed by the review workflow" / link out to the PR). Honors the
product-spec non-goal that controls must not appear actionable while doing nothing.
- Pros: smallest correct increment; no governance/auth/state-transition design
  needed; stays within the existing read-only GitHub client.
- Cons: humans still act on the PR in GitHub (or via the orchestrator), not from
  this page. Acceptable for v1; a follow-up feature can add governed write actions.

**Option B — Wire merge/request-changes directly to GitHub from the UI.**
- Cons: bypasses the orchestrator/human review boundary; needs write auth, task
  state-transition coupling (`review_passed`/`change_requested`), and conflict
  handling. Too large for v1; deferred to a dedicated follow-up feature.

### Q4 — Auth for GitHub reads

**Option A — Existing backend service token (CHOSEN).** v1 is read-only; the
service token already reads files and lists PRs for these repos.
- Pros: zero new identity work; consistent with current document/PR endpoints.
- Cons: all users see what the service token can see (acceptable — these are the
  same repos already surfaced).

**Option B — Per-user GitHub token / OAuth.** A larger identity feature; only
warranted once governed write actions (Q3 Option B) are in scope. Deferred.

---

## 4. Chosen design

A **read-only, additive** vertical slice. No DB schema changes, no orchestrator
changes, no task-lifecycle changes.

**Resolved open questions:** Q1 → live-from-GitHub backend endpoint;
Q2 → merged thread (GitHub reviews/comments + task-log verdict);
Q3 → read-only v1, neutralize action buttons (governed writes deferred);
Q4 → existing backend service token.

### Data flow (new)
```
TaskReviewView
  → workflowApi GET /bff/workflow-backend/api/workspaces/{ws}/tasks/{taskId}/diff
  → workflowApi GET /bff/workflow-backend/api/workspaces/{ws}/tasks/{taskId}/review-thread
        → (BFF proxy: path mapping → workflow-backend)
              → backend resolves task → pr/workspace_pr → (owner, repo, prNumber)
              → github.Client: GetPRFiles / GetPRDiff / GetPRReviews / GetPRComments
              → { success, data } envelope
  + task.log (already in hand) merged into the thread client-side
```

Endpoints are **PR/repo-aware**: when a task has both `pr` and `workspace_pr`
(or multiple repo PRs), the request carries the selected repo/PR so the diff and
thread reflect the repo chosen in the existing repo-selector pills. Suggested
shape: `?repo=<repo_id>` (defaults to the primary `pr`).

### Spec tab
Render from data the FE already holds: the task narrative/spec — `task.title`,
`task.description`, `depends_on`, `status`, and (if needed) the task's `tasks.md`
section via the existing document-content endpoint. No new backend work expected
for the Spec tab; it draws on `TaskDetail`/`TaskSummary` fields already present.

### Affected repositories
- `workflow-backend` — new GitHub client read methods + two read endpoints.
- `workflow-bff` — proxy path-mapping / allowlist entries for the two new routes
  (config; verify whether the generic root-path proxy already admits them).
- `digital-factory-ui` — service methods + types + hooks; wire diff, thread, and
  Spec tab into `task-review-view.tsx`; honest empty/loading/error states;
  neutralize the non-functional action buttons.

### Compatibility / operational implications
- Purely additive endpoints; no change to existing payloads or task schema.
- Add a short server-side cache (keyed by PR number + head SHA) to soften GitHub
  rate limits; cache is best-effort and safe to disable.
- No migration, no rollout coupling. The page degrades gracefully to empty states
  if an endpoint is unavailable.

---

## 5. Dependency analysis

**Internal**
- FE diff/thread rendering depends on the backend endpoints' **response DTO
  shapes** being frozen (T1/T2 before T4).
- FE reachability depends on the BFF admitting the new routes (T3 before T4).
- Repo/PR resolution depends on tasks exposing `pr`/`workspace_pr` (already true).

**External**
- GitHub REST API availability + rate limits (mitigated by caching).
- GitHub token scope must permit reading PR files, diffs, reviews, and comments
  for the target repos (verify during T1/T2; same service token as today).

**Blocking decisions** — all resolved in §3/§4 (Q1–Q4). None left open.

**Vendor / tooling** — GitHub REST API; no new vendor.

**Configuration** — BFF path-mapping entries for the two new routes; existing
`GITHUB_TOKEN` scope confirmation. No new env vars expected.

**Release** — no DB migration; no ordered cross-service release required (FE
degrades to empty states until backend routes ship).

---

## 6. Parallelization / blocking analysis

Proposed task decomposition (formalized in Phase 2). One repo per task.

```
(no external/human decisions outstanding — Q1–Q4 resolved in this design)

T1: workflow-backend — GitHub client PR files+diff methods + read endpoint
                       GET .../tasks/{taskId}/diff?repo=
T2: workflow-backend — GitHub client PR reviews+comments methods + read endpoint
                       GET .../tasks/{taskId}/review-thread?repo=
  └── T1 and T2 run in parallel
  └── Can begin now — no blockers
  │
  T3: workflow-bff — add proxy path-mapping/allowlist for the two new routes
        └── BLOCKED on T1/T2 (route paths must be frozen before they are mapped)
        │
        T4: digital-factory-ui — service methods + types + React Query hooks
                                  (diff + review-thread clients)
              └── BLOCKED on T1/T2 (response DTO shapes must be frozen)
              └── BLOCKED on T3 (routes must be reachable through the BFF)
              │
              T5: digital-factory-ui — wire task-review-view.tsx: real diff panel
                                       (files, hunks, +/- counts, multi-repo
                                       selector), merged review thread, Spec tab,
                                       empty/loading/error states, neutralize the
                                       Merge / Request-changes buttons
                    └── BLOCKED on T4 (data hooks must exist)
```

- **Wave 1 (parallel):** T1, T2 — independent backend endpoints, start immediately.
- **Wave 2:** T3 — BFF config, once route paths are frozen by T1/T2.
- **Wave 3:** T4 — FE data layer, once shapes are frozen (T1/T2) and routes are
  reachable (T3).
- **Wave 4:** T5 — FE view integration, once hooks exist (T4).

T5 is intentionally a single FE task (one editor of `task-review-view.tsx`) to
avoid two tasks mutating the same 361-LOC component in parallel.

---

## 7. Repository impact

| Repo (`workspace.yaml` id) | Change | Tasks |
|---|---|---|
| `workflow-backend` | New read-only GitHub client methods (PR files/diff, PR reviews + review/issue comments) and two Gin read endpoints under the existing task route group. No DB changes. | T1, T2 |
| `workflow-bff` | Proxy path-mapping / allowlist entries for the two new routes (config; verify generic root-path proxy coverage first). | T3 |
| `digital-factory-ui` | Service methods + types + hooks; wire diff, merged review thread, and Spec tab into `task-review-view.tsx`; empty/loading/error states; neutralize non-functional action buttons. | T4, T5 |

All repo ids match `workspace.yaml -> repos[].id`. No task writes to more than one
repo.

---

## 8. Validation and release impact

**Testing**
- `workflow-backend` (Go): unit tests for new GitHub client methods using an
  `httptest` server (the existing pattern — `newWithBaseURL`); handler tests for
  the two endpoints incl. not-found, unauthorized, rate-limit, and the
  no-PR-yet empty case. `golangci-lint run` must pass (zero errors).
- `workflow-bff` (Go): routing-table test that the new paths resolve to the
  `workflow-backend` upstream; `golangci-lint run`.
- `digital-factory-ui`: component/unit tests for the diff panel, merged thread
  ordering, Spec tab, and each of loading / empty / error / no-PR states; lint +
  the repo's test runner. Full suite must pass before any PR (Test-before-PR rule).

**Migration / config**
- No DB migration. BFF path-mapping config addition. Confirm `GITHUB_TOKEN` scope
  covers PR read APIs for the target repos.

**Rollout / backward compatibility**
- Additive endpoints; existing payloads unchanged. FE degrades to honest empty
  states if backend routes are absent, so there is no hard release ordering — but
  the natural order is backend (T1/T2) → BFF (T3) → FE (T4/T5).

**Handoff implications**
- v1 is read-only. Governed write actions (Merge / Request-changes from the page,
  per-user auth) are explicitly deferred to a follow-up feature; this design notes
  the seam (Q3 Option B / Q4 Option B) so the follow-up can build on it.

---

## Figma
The product spec contains **no Figma links** (it states no design was provided and
that the existing visual layout is preserved — a non-goal to redesign). Per the
workspace Figma propagation rule, no `## Figma` mapping is required for this
design. If a Figma design is added to the product spec later, this section must be
populated and the relevant UI tasks (T5) must carry a `### Figma` subsection
before they are marked `ready`.
