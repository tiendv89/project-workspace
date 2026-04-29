# Product Spec - Check Status Across All Branches

## Feature
- Feature ID: `feature-status-dashboard-check-status-across-all-branches`
- Title: Check status across all branches

## Problem

The dashboard currently depends on local workspace files for feature and task
state. That makes the UI fragile in two ways:

1. The browser only sees whatever exists on the local checked-out workspace.
2. Task progress can live on pull request branches before it is merged back to
   `main`, so a local filesystem scan can show stale task status.

For this workflow dashboard, the management repo on GitHub should be the read
source. The UI should load feature and task state through API endpoints that read
GitHub repository snapshots, then receive task status changes from GitHub
webhook events while the page is open.

## Goal

Redesign the feature status dashboard data flow so it no longer loads features or
tasks directly from local files. Instead:

- Feature list data is loaded from the GitHub codeload ZIP for
  `Kadamato/project-workspace` on `main`.
- Each `docs/features/<feature_id>/status.yaml` file represents one feature and
  contains that feature's status.
- Feature detail data is loaded on demand from the same GitHub snapshot by
  combining the feature's `status.yaml` with matching `tasks/T<n>.yaml` files.
- Task status updates are synced in the background through a Next.js webhook and
  Server-Sent Events flow, without adding a separate Express server.

## Requirements

### Feature List Loading

1. Add a Next.js API route that downloads:

   ```bash
   curl -sL 'https://codeload.github.com/Kadamato/project-workspace/zip/refs/heads/main'
   ```

2. The API must parse the ZIP with `JSZip`.
3. The API must scan only files under:

   ```text
   docs/features/*/status.yaml
   ```

4. Each `status.yaml` is treated as exactly one feature.
5. The API response must return the feature file path and raw YAML content, plus
   parsed feature metadata when parsing succeeds.
6. The dashboard feature list must use this API response instead of local
   filesystem readers.

### Feature Detail Loading

1. When the user clicks a feature, the detail page must call a Next.js API route
   for that feature ID.
2. The route must download the GitHub codeload ZIP for `main`.
3. The route must read:

   ```text
   docs/features/<feature_id>/status.yaml
   docs/features/<feature_id>/tasks/T*.yaml
   ```

4. The route must parse `status.yaml` as the feature status source.
5. The route must parse task YAML files and include only task files whose
   `branch` starts with:

   ```text
   feature/<feature_id>-T
   ```

6. The detail response must combine:
   - feature ID
   - feature status metadata
   - task directory
   - branch prefix
   - task count
   - task records with `path`, `id`, `title`, `status`, `branch`, and raw
     `content`
7. Task records must be sorted by numeric task ID.

### Background Task Status Sync

1. Add a browser hook equivalent to:

   ```typescript
   export function useGitHubSync() {
     const [tasks, setTasks] = useState(INITIAL_TASKS);

     useEffect(() => {
       const es = new EventSource("/events");

       es.onmessage = (event) => {
         const { branch, status } = JSON.parse(event.data);
         setTasks((prev) =>
           prev.map((task) =>
             task.branch === branch ? { ...task, status } : task,
           ),
         );
       };

       return () => es.close();
     }, []);

     return tasks;
   }
   ```

2. The browser must rely on native `EventSource` reconnection instead of custom
   reconnect logic.
3. The event payload must include enough information to update the correct task:
   `featureId`, `taskId`, `branch`, `status`, and event source metadata.
4. The background sync must update visible task status as soon as a matching
   GitHub event is received.
5. The background sync must not mutate local workspace files.

### GitHub Webhook

1. Replace the Express webhook design with a Next.js API route.
2. The webhook route must read the raw request body before JSON parsing.
3. The webhook route must validate `x-hub-signature-256` with:
   - `GH_SECRET`
   - HMAC SHA-256
   - timing-safe comparison
4. Invalid or missing signatures must return `401`.
5. The route must process GitHub pull request events.
6. For each pull request event, the route must find changed files whose basename
   starts with `T` and ends with `.yaml` or `.yml` under:

   ```text
   docs/features/<feature_id>/tasks/
   ```

7. The route must update the correct feature/task by deriving:
   - `featureId` from the path
   - `taskId` from the filename
   - `branch` from the task YAML or PR head branch
8. The route must broadcast task status changes to connected `/events` clients.

### Rollback and Edge Cases

1. If a pull request is closed without merge, the UI must rollback to the task
   status from the latest `main` snapshot.
2. If a pull request is merged, the UI must reload or reconcile from the latest
   `main` snapshot after GitHub updates `main`.
3. If a pull request branch is deleted, the UI must not keep a stale status that
   came from that branch.
4. A task must not remain visually `done` only because a deleted or closed pull
   request previously emitted `done`.
5. `done` should be trusted only when the latest task YAML source still says
   `done`.
6. Duplicate webhook deliveries must be idempotent.
7. Webhook events that touch multiple task YAML files must update all matching
   tasks.
8. Invalid YAML, missing task files, deleted task files, renamed task files, and
   PR-head content fetch failures must produce safe rollback or no-op behavior,
   not a broken UI.

## Non-Goals

- Do not load feature or task data from the local workspace filesystem.
- Do not add or keep a separate Express server for GitHub webhooks.
- Do not execute agent tasks.
- Do not claim, approve, or mark tasks `done` from the dashboard.
- Do not write back to `docs/features/**` from the dashboard sync flow.
- Do not infer task `done` only from pull request state.
- Do not change the task YAML schema.

## Acceptance Criteria

- The feature list API downloads the GitHub ZIP for `main` and returns every
  `docs/features/*/status.yaml` file as one feature record.
- The dashboard feature list no longer depends on local filesystem readers.
- Clicking `feature-status-dashboard-v2` loads
  `docs/features/feature-status-dashboard-v2/status.yaml` and matching
  `docs/features/feature-status-dashboard-v2/tasks/T*.yaml` files from the
  GitHub ZIP.
- The feature detail API returns task records only when `task.branch` starts with
  `feature/feature-status-dashboard-v2-T`.
- A valid GitHub pull request webhook that changes
  `docs/features/<feature_id>/tasks/T<n>.yaml` broadcasts the new task status to
  connected `/events` clients.
- The client updates the matching task by `branch` without a full page reload.
- Invalid webhook signatures are rejected before JSON parsing.
- Closing a pull request without merge rolls the visible task status back to the
  latest status from `main`.
- Deleting a task branch or receiving a stale PR event does not leave the UI
  showing `done` unless the latest trusted task YAML still has `status: done`.
