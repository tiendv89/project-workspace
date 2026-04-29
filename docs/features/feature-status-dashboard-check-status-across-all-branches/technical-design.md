# Technical Design - Check Status Across All Branches

## Feature
- Feature ID: `feature-status-dashboard-check-status-across-all-branches`
- Title: Check status across all branches

## 1. Current State

### Existing Dashboard Model

The dashboard design previously assumed that feature and task state are loaded
from local management repo files:

- `docs/features/<feature_id>/status.yaml`
- `docs/features/<feature_id>/tasks/T<n>.yaml`

That local-first model is no longer the target. The new requirement is to load
feature and task data through GitHub-backed API routes and reserve local files for
the workflow management repo itself, not for dashboard reads.

### Target Source Model

The read source becomes the GitHub repository snapshot:

```text
https://codeload.github.com/Kadamato/project-workspace/zip/refs/heads/main
```

The dashboard reads this ZIP through Next.js API routes, extracts workflow YAML
files with `JSZip`, parses YAML with `yaml`, and sends normalized JSON to the
client.

### Runtime Status Model

GitHub webhook events provide near-real-time task status updates while the web UI
is open. Next.js receives webhook events, validates the GitHub signature, detects
changed task YAML files in pull requests, resolves the affected feature/task, and
broadcasts updates through Server-Sent Events at `/events`.

## 2. Problem Framing

### What Needs To Change

- Remove dashboard dependency on local filesystem feature/task readers.
- Add GitHub ZIP snapshot loaders for feature list and feature detail.
- Add a feature detail loader that combines one `status.yaml` with matching
  `tasks/T*.yaml` records.
- Add a Next.js webhook route that replaces the previous Express webhook shape.
- Add a browser background sync hook based on `EventSource`.
- Add rollback behavior for PR close, PR branch delete, missing task files, and
  stale events.

### What Must Remain Stable

- Feature state remains represented by `docs/features/<feature_id>/status.yaml`.
- Task state remains represented by `docs/features/<feature_id>/tasks/T<n>.yaml`.
- Task YAML schema does not change.
- Dashboard sync must not execute tasks or approve work.
- `status: done` remains a workflow state from YAML, not a PR-state shortcut.

### Fixed Assumptions

- GitHub repo: `Kadamato/project-workspace`
- Default snapshot ref: `refs/heads/main`
- Feature root: `docs/features/`
- Feature detail branch prefix: `feature/<feature_id>-T`
- Next.js runs with the Node.js runtime for webhook signature validation.
- `GH_SECRET` is configured for GitHub webhook verification.
- A long-running Next.js server process is available for in-memory SSE fanout.
  If deployed to serverless/multi-instance infrastructure later, the event bus
  must move to Redis, Pusher, Ably, or another shared pub/sub layer.

## 3. Options Considered

### Option A - Continue Reading Local Files

The dashboard keeps scanning the local management repo and optionally refreshes
with git commands.

**Pros:**
- Simple in local development.
- Existing readers can stay mostly unchanged.

**Cons:**
- Violates the new requirement.
- UI depends on local checkout state.
- Active PR branch status can remain invisible.

**Verdict:** Rejected.

### Option B - Read GitHub ZIP Snapshots For List And Detail (Chosen)

The dashboard calls Next.js API routes that download the GitHub codeload ZIP,
extract feature/task YAML, parse it, and return normalized JSON.

**Pros:**
- Removes local filesystem dependency.
- Uses one consistent GitHub source for feature and detail pages.
- Works without checking out branches locally.
- Easy to cache and invalidate by ref.

**Cons:**
- ZIP download can be heavy if called too often.
- Needs error handling for GitHub rate limits and unavailable snapshots.
- `main` snapshots are eventually consistent after merges.

**Verdict:** Chosen for feature list and feature detail reads.

### Option C - Use GitHub Contents API For Every File

The dashboard lists directories and fetches YAML files through the GitHub
Contents API.

**Pros:**
- Fetches only needed files.
- Can request specific refs.

**Cons:**
- Requires many API calls for feature list and detail pages.
- More rate-limit pressure.
- More complex pagination and auth handling.

**Verdict:** Rejected for initial list/detail loading. It can be used by the
webhook path to fetch a specific PR-head task file if needed.

### Option D - Poll GitHub In The Browser

The browser polls the GitHub ZIP or GitHub API directly.

**Pros:**
- No backend loader needed.

**Cons:**
- Exposes API details to the client.
- Harder to hide tokens for private repos or higher rate limits.
- No secure webhook signature handling.

**Verdict:** Rejected.

### Option E - Next.js Webhook Plus SSE For Runtime Sync (Chosen)

GitHub calls a Next.js webhook route. The route validates signatures, detects
changed task YAML files in PRs, parses the latest relevant task YAML, and
broadcasts updates through `/events`.

**Pros:**
- No Express server.
- Browser updates immediately through native `EventSource`.
- Webhook validation stays server-side.
- PR close/delete rollback can be centralized.

**Cons:**
- In-memory SSE only works reliably in a single long-running process.
- Requires a small event bus and dedupe layer.

**Verdict:** Chosen for background task status sync.

## 4. Chosen Design

### High-Level Data Flow

```text
Feature list page
  -> GET /api/github/features
     -> download codeload ZIP for main
     -> extract docs/features/*/status.yaml
     -> parse YAML and return feature records

Feature detail page
  -> GET /api/github/features/:featureId
     -> download codeload ZIP for main
     -> read docs/features/:featureId/status.yaml
     -> read docs/features/:featureId/tasks/T*.yaml
     -> include tasks whose branch starts with feature/<featureId>-T
     -> return feature status plus task records

GitHub webhook
  -> POST /api/webhooks/github
     -> verify raw body signature
     -> process pull_request and delete events
     -> find affected docs/features/*/tasks/T*.yaml files
     -> fetch task YAML from PR head or main snapshot
     -> broadcast task status event

Browser task detail state
  -> EventSource("/events")
     -> update matching task by branch / featureId / taskId
```

### Files To Add Or Change In `digital-factory-ui`

```text
src/app/api/github/features/route.ts
src/app/api/github/features/[featureId]/route.ts
src/app/api/webhooks/github/route.ts
src/app/events/route.ts
src/hooks/use-github-sync.ts
src/lib/github/archive.ts
src/lib/github/feature-snapshot.ts
src/lib/github/task-detail.ts
src/lib/github/webhook-signature.ts
src/lib/github/pull-request-files.ts
src/lib/github/task-status-events.ts
src/types/github-workflow.ts
```

Names can be adjusted to match the implementation repo conventions, but the
boundaries should stay the same.

## 5. Snapshot Archive Loader

### `src/lib/github/archive.ts`

Responsibility:

- Download the GitHub codeload ZIP for a configurable repo/ref.
- Load the archive with `JSZip`.
- Detect the generated root folder dynamically.
- Expose helpers to read text files and list file names.

Core behavior:

```typescript
const archiveUrl =
  "https://codeload.github.com/Kadamato/project-workspace/zip/refs/heads/main";

const response = await fetch(archiveUrl, {
  cache: "no-store",
  headers: {
    Accept: "application/zip",
  },
});

if (!response.ok) {
  throw new Error(`GitHub archive request failed: ${response.status}`);
}

const input = Buffer.from(await response.arrayBuffer());
const archive = await JSZip.loadAsync(input);
const root = Object.keys(archive.files)[0].split("/")[0] + "/";
```

The loader must not assume `project-workspace-main/` forever. It should support
GitHub's generated root folder by deriving it from archive file names.

### Caching

Use short-lived server-side caching only if needed:

- default: `cache: "no-store"` for correctness
- optional in-memory TTL: 10 to 30 seconds for the same repo/ref

Webhook rollback paths must be able to bypass the cache after PR close/merge so
the UI does not keep stale status.

## 6. Feature List API

### Route

```text
GET /api/github/features
```

### Behavior

1. Download the `main` ZIP snapshot.
2. Iterate archive files in sorted order.
3. Select files matching:

   ```text
   docs/features/<feature_id>/status.yaml
   ```

4. Read each status YAML as string.
5. Parse YAML.
6. Return raw and parsed records.

### Response Shape

```typescript
interface FeatureStatusRecord {
  featureId: string;
  path: string;
  content: string;
  status: Record<string, unknown> | null;
  parseError?: string;
}

interface FeatureListResponse {
  repo: "Kadamato/project-workspace";
  ref: "refs/heads/main";
  count: number;
  files: FeatureStatusRecord[];
}
```

The route should tolerate one invalid `status.yaml` by returning that record with
`parseError`; it should not fail the entire feature list unless the archive cannot
be downloaded or parsed.

## 7. Feature Detail API

### Route

```text
GET /api/github/features/[featureId]
```

### Behavior

1. Validate `featureId` to prevent path traversal:

   ```text
   ^[A-Za-z0-9._-]+$
   ```

2. Download the `main` ZIP snapshot.
3. Read:

   ```text
   docs/features/<featureId>/status.yaml
   ```

4. Scan:

   ```text
   docs/features/<featureId>/tasks/T*.yaml
   docs/features/<featureId>/tasks/T*.yml
   ```

5. Parse each task YAML.
6. Include a task only when:

   ```typescript
   typeof task.branch === "string" &&
   task.branch.startsWith(`feature/${featureId}-T`)
   ```

7. Return sorted task records.

### Response Shape

```typescript
interface FeatureTaskRecord {
  path: string;
  id: string;
  title?: string;
  status?: string;
  branch: string;
  content: string;
  parsed: Record<string, unknown>;
}

interface FeatureDetailResponse {
  featureId: string;
  statusPath: string;
  statusContent: string;
  status: Record<string, unknown>;
  taskDir: string;
  branchPrefix: string;
  count: number;
  records: FeatureTaskRecord[];
}
```

### Example Equivalent

The route implements the same extraction behavior as:

```bash
FEATURE_ID='feature-status-dashboard-v2'

curl -sL 'https://codeload.github.com/Kadamato/project-workspace/zip/refs/heads/main' |
env FEATURE_ID="$FEATURE_ID" bun -e '/* JSZip + YAML extraction */'
```

but exposes it as a reusable Next.js API endpoint for the dashboard.

## 8. SSE Event Flow

### Route

```text
GET /events
```

This is implemented by `src/app/events/route.ts` so the browser can use:

```typescript
const es = new EventSource("/events");
```

### Event Payload

```typescript
interface TaskStatusEvent {
  type:
    | "task_status_changed"
    | "task_status_rollback"
    | "task_snapshot_invalidated";
  featureId: string;
  taskId: string;
  branch: string;
  status: string;
  source: "pr_head" | "main_snapshot" | "branch_delete" | "pr_closed";
  githubDeliveryId?: string;
  pullRequest?: {
    number: number;
    state: "open" | "closed";
    merged: boolean;
    url: string;
  };
  reason?: string;
}
```

### Client Hook

```typescript
export function useGitHubSync(initialTasks: TaskRecord[]) {
  const [tasks, setTasks] = useState(initialTasks);

  useEffect(() => {
    const es = new EventSource("/events");

    es.onmessage = (event) => {
      const update = JSON.parse(event.data) as TaskStatusEvent;

      setTasks((prev) =>
        prev.map((task) => {
          const sameBranch = task.branch === update.branch;
          const sameTask =
            task.featureId === update.featureId && task.id === update.taskId;

          return sameBranch || sameTask
            ? { ...task, status: update.status }
            : task;
        }),
      );
    };

    return () => es.close();
  }, []);

  return tasks;
}
```

Native browser reconnect behavior is enough for the first pass. The hook should
not add custom reconnect timers.

## 9. GitHub Webhook Route

### Route

```text
POST /api/webhooks/github
```

### Runtime

```typescript
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
```

### Signature Verification

Next.js must read the raw body as bytes before parsing JSON:

```typescript
const body = Buffer.from(await request.arrayBuffer());
const signature = request.headers.get("x-hub-signature-256");

const expected =
  "sha256=" +
  crypto.createHmac("sha256", process.env.GH_SECRET ?? "")
    .update(body)
    .digest("hex");

const valid =
  typeof signature === "string" &&
  signature.length === expected.length &&
  crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));

if (!valid) {
  return new Response("Invalid signature", { status: 401 });
}

const payload = JSON.parse(body.toString("utf8"));
```

The length check is required because `crypto.timingSafeEqual()` throws when buffer
lengths differ.

### Event Types

Handle these GitHub events:

```text
pull_request
delete
ping
```

`ping` returns `200` after signature verification.

### Pull Request Processing

For `pull_request` events:

1. Read action and PR metadata from the payload.
2. Fetch the PR changed-file list from GitHub:

   ```text
   GET /repos/:owner/:repo/pulls/:pull_number/files
   ```

3. Filter files whose path matches:

   ```text
   ^docs/features/([^/]+)/tasks/(T[^/]*\.ya?ml)$
   ```

4. For each matched path, derive:
   - `featureId` from the first capture group
   - `taskId` from the filename without extension
   - `branch` from parsed task YAML when available, otherwise PR head ref
5. For active PR actions such as `opened`, `reopened`, `synchronize`,
   `ready_for_review`, and `edited`, fetch the task YAML at the PR head SHA and
   broadcast its parsed status.
6. For `closed`:
   - if `pull_request.merged === true`, reload the task from `main` after a short
     retry/backoff because GitHub may deliver the webhook before codeload shows
     the new `main` archive.
   - if `merged === false`, rollback to the latest task status from `main`.
7. If the task file was removed or renamed in the PR, fallback to the latest
   `main` snapshot for that feature/task.

### Delete Event Processing

For `delete` events:

1. Process only branch deletes:

   ```typescript
   payload.ref_type === "branch"
   ```

2. If the deleted branch matches:

   ```text
   feature/<feature_id>-T<n>
   ```

   derive the `featureId` and `taskId`.
3. Reload the task status from `main`.
4. Broadcast a `task_status_rollback` event with `source: "branch_delete"`.

This prevents the UI from keeping a stale status that came from a deleted task
branch.

## 10. Rollback Rules

### Trusted Sources

Use this source priority:

1. PR head task YAML for active PR updates.
2. `main` snapshot task YAML after PR close, branch delete, missing PR head file,
   or invalid PR head YAML.
3. Existing browser state only when neither source can be fetched.

### Status Regression Rules

- A PR close without merge must not leave the browser on a PR-head status.
- A branch delete must invalidate task status emitted from that branch.
- `status: done` is trusted only if the latest selected YAML source says `done`.
- PR state alone never maps to `done`.
- If rollback cannot fetch `main`, broadcast
  `task_snapshot_invalidated` so the UI can mark the task as needing refresh
  rather than showing stale success.

### Duplicate Delivery Rules

Keep an in-memory TTL set keyed by:

```text
github_delivery_id + event_name + action + task_path + head_sha
```

Duplicate deliveries within the TTL return `200` and do not rebroadcast.

## 11. Dependency Analysis

### Internal Dependencies

| Dependency | Use | Notes |
|---|---|---|
| Next.js App Router | API routes and `/events` route | Must use Node.js runtime for webhook crypto. |
| `JSZip` | GitHub ZIP parsing | Already shown in the required extraction command. |
| `yaml` | YAML parsing | Parses `status.yaml` and `T*.yaml`. |
| Browser `EventSource` | Background task status updates | Native reconnect is sufficient. |
| Feature/task UI components | Consume API JSON and hook state | Must stop reading local workspace files. |

### External Dependencies

| Dependency | Use | Notes |
|---|---|---|
| GitHub codeload ZIP | Feature list/detail snapshot | Public repo can be unauthenticated; token may be added later. |
| GitHub Webhooks | Runtime updates | Requires `GH_SECRET`. |
| GitHub Pull Request Files API | Find changed task YAML paths | Use `GITHUB_TOKEN` if rate limits or private repo access require it. |

### Configuration

```text
GITHUB_OWNER=Kadamato
GITHUB_REPO=project-workspace
GITHUB_REF=refs/heads/main
GH_SECRET=<github webhook secret>
GITHUB_TOKEN=<optional token for PR files API>
```

## 12. Parallelization / Blocking Analysis

```text
T1: GitHub snapshot loader and YAML parsing
  - No blockers.
  - Establishes the trusted main snapshot reader used by APIs and rollback.

T4: GitHub webhook verification and task file detection
  - No blockers.
  - Runs in parallel with T1 because webhook verification and task path parsing
    do not depend on the feature API routes.

T2: Feature list and detail APIs
  └── BLOCKED on T1 (archive reader, YAML parser, and path matchers must be stable)

T5: SSE event bus and client sync hook
  └── BLOCKED on T4 (webhook event payload and affected-task identity must be stable)

T3: Dashboard API data migration
  └── BLOCKED on T2 (feature list/detail response contracts must be stable)

T6: Rollback and stale-state guards
  └── BLOCKED on T1 (rollback must read latest main snapshot)
  └── BLOCKED on T4 (PR close/delete events and task identity must be available)
  └── BLOCKED on T5 (rollback must broadcast corrected task status to clients)

T7: Verification and operational documentation
  └── BLOCKED on T2/T3 (GitHub-backed list/detail UI must be testable)
  └── BLOCKED on T4/T5/T6 (webhook, SSE, and rollback behavior must be final)
```

`T1` and `T4` can begin immediately and run in parallel. `T2` can start as soon
as `T1` freezes the snapshot-loader contract. `T5` can start after `T4` defines
the event payload. `T3` and `T6` can then proceed in parallel once their
respective blockers are satisfied.

## 13. Repository Impact

| Repo id | Impact | Why |
|---|---|---|
| `digital-factory-ui` | Primary implementation | Adds GitHub-backed APIs, webhook route, SSE route, and UI hook. |
| `management-repo` | Read source through GitHub snapshot | No dashboard writes to workflow YAML. |
| `workflow` | No implementation change | Task lifecycle rules remain unchanged. |

## 14. Validation Plan

### Unit Tests

- Archive loader derives root folder dynamically.
- Feature list extracts only `docs/features/*/status.yaml`.
- Feature detail rejects unsafe `featureId` values.
- Feature detail includes only tasks whose branch starts with
  `feature/<featureId>-T`.
- Task sorting uses numeric task IDs.
- Webhook signature validation rejects missing, malformed, and mismatched
  signatures without throwing on length mismatch.
- Pull request file parser extracts `featureId` and `taskId` from
  `docs/features/<feature_id>/tasks/T*.yaml`.
- Rollback logic chooses `main` snapshot for PR close without merge and branch
  delete.

### Integration Tests

- `GET /api/github/features` returns feature records from a mocked ZIP.
- `GET /api/github/features/feature-status-dashboard-v2` returns status plus
  task records from a mocked ZIP.
- `POST /api/webhooks/github` with a valid PR event broadcasts a task status
  event.
- Duplicate webhook delivery returns `200` and does not emit twice.
- Invalid YAML in one task does not break the entire feature detail response.

### Manual Smoke Test

1. Start the Next.js dashboard.
2. Open the feature list and confirm it loads from `/api/github/features`.
3. Click `feature-status-dashboard-v2`.
4. Confirm the detail view shows feature status plus matching task records.
5. Open an `EventSource("/events")` connection from the page.
6. Send a signed GitHub webhook fixture for a PR touching
   `docs/features/feature-status-dashboard-v2/tasks/T1.yaml`.
7. Confirm the visible T1 status updates without a full page reload.
8. Send a signed PR `closed` event with `merged: false`.
9. Confirm T1 rolls back to the latest `main` snapshot status.
10. Send a signed branch `delete` event for
    `feature/feature-status-dashboard-v2-T1`.
11. Confirm the UI does not keep a stale PR-head `done` status.

## 15. Release Notes

- The dashboard no longer reads feature/task status directly from local workflow
  files.
- GitHub `main` codeload ZIP is the feature list and detail snapshot source.
- GitHub webhooks plus `/events` provide background task status updates.
- The dashboard does not write workflow YAML or infer `done` from PR state.
- A production multi-instance deployment needs shared pub/sub for SSE fanout.
