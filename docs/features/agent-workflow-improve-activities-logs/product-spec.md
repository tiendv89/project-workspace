
# Product Specification

## Feature
- Feature ID: `feature-scoped-activity-log`
- Title: Feature-scoped activity log fetch (drop workspace-wide fetch + client-side filter)

## Problem
The Feature workbench UI (`digital-factory-ui`, `FeatureWorkbench` in
`src/components/features/feature-workbench.tsx`) shows an "Activity" panel scoped
to the currently open feature. Today it gets that data by:

1. Calling `useActivity(workspaceId)` (`src/hooks/board/use-activity.ts`), which
   calls `listActivity(workspaceId, { audience: "client" })`
   (`src/services/workflow-backend/client.ts`) with **no `featureId`**.
2. That hits `GET /api/workspaces/:workspaceId/activity?audience=client` on
   `workflow-backend`, which returns **every activity event in the whole
   workspace** (`WorkspaceHandler.ListActivity` →
   `WorkspaceService.ListActivity` → `Reader.ListActivityEvents` in
   `internal/database/queries.go`, which only adds a `feature_id`/`task_id`
   `WHERE` clause when those query params are non-empty).
3. `FeatureWorkbench` then filters the full result client-side, matching events
   whose `feature_id` is in `{feature.id, feature.feature_id, feature.feature_name}`
   or whose `task_id` belongs to one of the feature's own tasks.

This means every feature-detail page view pulls the activity log for the
**entire workspace** over the network and repeats an O(n) filter in the
browser, which will not scale as the number of logged events grows across
features and tasks in a workspace.

The backend API already supports scoping: `ListActivity`'s handler reads
`featureId`/`taskId` from the query string
(`internal/handler/workspace.go:ListActivity`) and
`Reader.ListActivityEvents(ctx, workspaceID, featureID, taskID)` /
`activityFilterClause` (`internal/database/queries.go`) already push a
`feature_id = $N` (and optional `task_id = $N`) predicate into the SQL query
when a `featureID` is supplied. No backend change is required — the frontend
simply isn't using the parameter that already exists.

## Goals
- When the Feature workbench is open for a given feature, the activity feed
  request must include that feature's ID so `workflow-backend` filters at the
  SQL layer and returns only that feature's events (plus their tasks' events,
  which the backend already includes once `feature_id` is scoped, since
  `activityFilterClause` matches on `feature_id` directly on
  `workspace_activity_events`).
- Remove the now-unnecessary client-side re-filtering in `FeatureWorkbench`
  (the `featureIds` set match / `activityTasksById` fallback match) once the
  server-side filter is in place, since the response will already be
  feature-scoped.
- Keep the existing `audience=client` behavior (action-label allowlist
  mapping in `WorkspaceService.ListActivity`) unchanged — only the additional
  `featureId` parameter is newly wired from the client.
- Preserve current UI behavior/appearance of the Activity panel — this is a
  data-fetching efficiency change, not a UX change.

## Non-goals
- No changes to `workflow-backend` (`internal/handler/workspace.go`,
  `internal/service/workspace.go`, `internal/database/queries.go`) — the
  `featureId`/`taskId` filter already exists and already works; this feature
  only changes what the frontend sends.
- Not making `featureId` a hard-required (400-on-missing) parameter on
  `GET /api/workspaces/:workspaceId/activity`. The endpoint keeps accepting an
  unscoped call for any future workspace-wide surface (e.g. a Dashboard
  "recent activity" widget referenced as future work in
  `docs/features/feature-status-dashboard-v2/product-spec.md`) — this feature
  does not touch that possibility either way, it just makes the one existing
  caller pass the parameter that's already available.
- No pagination/limit changes to the activity endpoint.
- No change to `taskId`-scoped activity fetches used elsewhere (e.g.
  `GetTask`'s embedded `Activity` array) — out of scope here.
- No change to the `workflow-backend` Go tests already covering
  `ListActivity` scoping (`TestListActivity_WorkspaceLevel_ReturnsEvents`,
  `TestActivityFilterClauseMatchesWorkflowNamesAndUUIDs`, etc.) since backend
  behavior is unchanged.

## Frontend changes (digital-factory-ui) — reference locations
- `src/services/workflow-backend/client.ts` — `listActivity(workspaceId, params)`
  already accepts an options bag; add `featureId` (and keep `taskId` as an
  optional future param) so it's serialized into the query string alongside
  `audience`.
- `src/hooks/board/use-activity.ts` — `useActivity` currently takes only
  `workspaceId`. Extend its signature to accept `featureId` and include it in
  both the `queryFn` call and the React Query `queryKey`
  (`workspaceKeys.activity(workspaceId, featureId)` or equivalent) so caching
  is correctly scoped per feature, not per workspace.
- `src/components/features/feature-workbench.tsx` — `FeatureWorkbench` calls
  `useActivity(workspaceId)`; update the call site to
  `useActivity(workspaceId, featureId)` (the component already has `featureId`
  as a prop). Remove the client-side `featureEvents` filter
  (`events.filter((e) => (e.feature_id ? featureIds.has(e.feature_id) : false) || ...)`)
  since the server response will already be scoped — pass `events` straight
  through to `FeatureIDEDocsPanel`'s `activityEvents` prop, keeping only the
  existing `.sort(...)` by `occurred_at`.
