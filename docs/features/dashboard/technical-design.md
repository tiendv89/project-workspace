# Technical Design

## Feature
- Feature ID: `dashboard`
- Title: `Workflow Dashboard Web`

## Figma

| Figma reference | Covers |
|---|---|
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-490 | Workspace connect / import screen |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-537 | Workspace detail Kanban board |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=35-752 | Status filter dropdown |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=36-935 | Workspace switcher dropdown |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=36-1108 | Task detail sheet |

---

## 1. Current State

The dashboard repository (`git@github.com:Kadamato/dashboard.git`) contains a React + Vite + TanStack Router application. It was built as a prototype with the following limitations:

- Auth state and workspace records live entirely in `localStorage`.
- The Kanban board renders hardcoded sample features and tasks — no real data is loaded.
- Repository import parses and stores a URL only; it never reads the repository.
- Private repository token is collected but discarded; it is never used.

The prior technical design (now superseded) proposed a compound-component architecture focused on the frontend only. The approved product spec changes the scope: the board must show **real workflow YAML from a connected GitHub repository**, with no additional backend service.

---

## 2. Problem Framing

### What must change
- Replace the hardcoded sample board with data loaded from the connected GitHub management repository.
- Implement a real "connect workspace" flow: user provides a GitHub repo URL and a Personal Access Token (PAT), the app reads the repo's workflow YAML via the GitHub REST API, and renders the board.
- Store the workspace config (repo URL + PAT) in `localStorage` so the board reloads without re-entering credentials.
- Add a sync button that re-fetches and re-parses the YAML on demand.

### What must remain stable
- The existing React + Vite + TanStack Router stack.
- The existing UI component library and visual design.
- The board layout: 7 status columns, feature rows, task cards, task detail sheet, search, and filter.
- No login or user account system.

### Fixed assumptions
- Only GitHub is supported in v1. GitLab and Bitbucket are out of scope.
- The PAT is stored in `localStorage`. This is accepted for v1 and noted as a future improvement.
- The app reads workflow YAML only; it never writes back to the repository.
- The management repository follows the standard workspace structure: `docs/features/<featureId>/status.yaml` and `docs/features/<featureId>/tasks/T<n>.yaml`.

---

## 3. Options Considered

### Option A — Frontend reads GitHub REST API directly (no backend)

The browser calls the GitHub REST API using the user-supplied PAT. No server is required.

**How it works:**
1. User provides a GitHub repo URL and PAT.
2. The app calls `GET /repos/{owner}/{repo}/git/trees/HEAD?recursive=1` to enumerate all files.
3. It filters for `docs/features/*/status.yaml` and `docs/features/*/tasks/T*.yaml`.
4. It fetches each file's content via `GET /repos/{owner}/{repo}/contents/{path}`, decodes the base64 payload, and parses it with `js-yaml`.
5. The parsed data is held in memory and rendered on the board.

**Pros:**
- Zero backend infrastructure — no server to build, deploy, or maintain.
- Immediate to implement within the existing frontend repo.
- GitHub API is stable, well-documented, and handles auth natively.
- Authenticated PAT requests allow 5,000 API calls per hour — well above interactive use needs.

**Cons:**
- PAT lives in `localStorage` — acceptable for v1, must be improved before broader rollout.
- Only GitHub is supported; extending to GitLab or Bitbucket requires additional API clients.
- Each YAML file is a separate API call. A large workspace (e.g. 20 features × 10 tasks = 200 files) makes ~201 requests on full load, which is within rate limits but adds latency.
- No offline or caching layer; every sync hits the GitHub API.

**Implementation impact:** Low. All changes are in the existing `dashboard` frontend repo.

**Dependency impact:** Adds `js-yaml` (or equivalent). No new services or repos.

---

### Option B — Thin backend server clones the repo and serves parsed YAML

A backend service clones the management repo server-side and exposes a REST API to the frontend.

**Pros:**
- PAT is never in the browser.
- Can cache parsed YAML and serve it fast.
- Can support multiple Git providers.

**Cons:**
- Requires a new backend service: design, implementation, infrastructure, and deployment.
- Increases scope and delivery time significantly.
- Unnecessary overhead for the v1 use case where a single user reads their own repo.

**Implementation impact:** High. New repo, new service, new infra.

---

## 4. Chosen Design

**Option A — Frontend reads GitHub REST API directly.**

The scope does not justify a backend service at this stage. The GitHub REST API covers all required read operations, the rate limits are comfortable for interactive use, and storing the PAT in `localStorage` is explicitly accepted for v1.

### Key design decisions

**GitHub API client** — a small typed module (`src/lib/github.ts`) wraps all GitHub REST calls. It holds the owner, repo, and PAT; exposes two methods: `listWorkflowFiles()` (tree API) and `fetchFile(path)` (contents API).

**YAML parser** — `js-yaml` is added as a dependency. A thin wrapper (`src/lib/yamlParser.ts`) decodes base64 content, parses YAML, and validates the minimal shape expected (feature with `featureId`, `title`, `featureStatus`; task with `taskId`, `title`, `status`). Malformed files are skipped with a console warning.

**Workspace config in localStorage** — a single key `workflow_workspace` stores `{ repoUrl, owner, repo, pat }`. The app reads this on boot; if present it skips the connect screen and goes directly to the board.

**No workspace list route in v1** — the connect screen is the entry point when no config exists. Adding multiple workspaces is deferred.

**Affected repository:** `dashboard` only.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Notes |
|---|---|---|---|
| `js-yaml` npm package | External library | Resolved | Drop-in YAML parser; actively maintained |
| GitHub REST API | External service | Resolved | PAT with `repo` read scope is sufficient |
| GitHub PAT from user | Runtime input | User-provided at connect time | App cannot function without it |
| Existing board UI components | Internal | Resolved — already in repo | Board, task sheet, filter, search are already built |
| `docs/features/` YAML structure | Data contract | Resolved — fixed by workspace convention | Parser assumes this layout; deviations are skipped with a warning |

No blocking unresolved dependencies.

---

## 6. Parallelization / Blocking Analysis

```
T1: GitHub API client + js-yaml setup (dashboard)
  └── Can begin now — no blockers

T2: Connect workspace flow — URL input, PAT input, validation, localStorage write (dashboard)
  └── Can begin now — no blockers
  └── T1 and T2 run in parallel

    T3: YAML loader — tree enumeration, file fetch, decode, parse, typed in-memory model (dashboard)
      └── BLOCKED on T1 (GitHub API client must exist before the loader can call it)

    T4: Wire real data to board — replace sample data with parsed model, sync button, error and empty states (dashboard)
      └── BLOCKED on T2 (connect flow must write config to localStorage that the board reads on boot)
      └── BLOCKED on T3 (YAML loader must exist and return typed data before the board can consume it)
```

Wave 1 (parallel): T1, T2
Wave 2: T3 (after T1)
Wave 3: T4 (after T2 and T3)

---

## 7. Repository Impact

| Repo | Impact |
|---|---|
| `dashboard` | All changes land here. Add `js-yaml`, add GitHub API client, add YAML parser, rewrite workspace connect flow, wire real data to board. |
| All others | No impact. |

---

## 8. Validation and Release Impact

**Testing:**
- Unit tests for the YAML parser: valid input, malformed YAML, missing required fields, base64 decode.
- Unit tests for GitHub URL parsing: HTTPS with and without `.git`, SSH format.
- Integration smoke test: connect to a real (or a dedicated test) public management repo and verify the board renders expected features and tasks.

**Migration / config:**
- Existing localStorage keys from the old demo flow (`workspaces`, `isLoggedIn`) will be ignored. The new key is `workflow_workspace`. No migration is needed — old keys sit unused.

**Rollout concerns:**
- No deployment gate needed. The app works for any user who provides a valid PAT with read access to their management repo.
- Rate limit risk is low for single-user interactive use (5,000 req/hour). If a workspace grows to hundreds of features, batching or caching should be evaluated before wider rollout.

**Backward compatibility:**
- The app has no real users or persistent server state. No backward compatibility concern.

**Handoff note:**
- The PAT-in-localStorage decision must be documented in the handoff as a known v1 limitation. Secure token handling (e.g. server-side storage or GitHub OAuth App) is the required next step before multi-user or production rollout.
