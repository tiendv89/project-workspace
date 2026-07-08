
# Technical Design

## Feature
- Feature ID: `agent-workflow-improve-activities-logs`
- Title: Feature-scoped activity log fetch (drop workspace-wide fetch + client-side filter)

## Current State
`digital-factory-ui`'s Feature workbench (`src/components/features/feature-workbench.tsx`,
`FeatureWorkbench`) shows an Activity panel scoped to the feature currently open. The
data path today is:

1. `FeatureWorkbench` calls `useActivity(workspaceId)` (no `featureId` passed) —
   `src/hooks/board/use-activity.ts`.
2. `useActivity` calls `listActivity(workspaceId, { audience: "client" })` —
   `src/services/workflow-backend/client.ts:114-120` — which builds
   `GET /api/workspaces/:workspaceId/activity?audience=client`, with no
   `featureId`/`taskId` query param.
3. The React Query cache key is `workspaceKeys.activity(workspaceId)` —
   `src/constants/query-keys.ts` — `["workspace", workspaceId, "activity", "client"]`,
   i.e. keyed **only by workspace**, not by feature.
4. On `workflow-backend`, `WorkspaceHandler.ListActivity`
   (`internal/handler/workspace.go:354-378`) already reads optional
   `featureId`/`taskId` query params into `domain.ActivityScope` and forwards them
   to `WorkspaceService.ListActivity` (`internal/service/workspace.go`), which
   calls `Reader.ListActivityEvents(ctx, workspaceID, scope.FeatureID, scope.TaskID)`
   (`internal/database/queries.go:~730`). `activityFilterClause`
   (`internal/database/queries.go:932-958`) only appends
   `AND feature_id = $N` / `AND task_id = $N` to the SQL `WHERE` clause when those
   strings are non-empty — so with no `featureId` supplied, the query returns
   **every** row in `workspace_activity_events` for the workspace.
5. Back in `FeatureWorkbench` (around the `featureEvents` computation near the end
   of the component body), the full unscoped list is filtered client-side:
   ```ts
   const featureIds = new Set([feature.id, feature.feature_id, feature.feature_name].filter(Boolean));
   const featureEvents = events
     .filter((e) => (e.feature_id ? featureIds.has(e.feature_id) : false) || (e.task_id ? activityTasksById.has(e.task_id) : false))
     .sort((a, b) => (b.occurred_at ?? "").localeCompare(a.occurred_at ?? ""));
   ```
   `featureEvents` is then passed to `FeatureIDEDocsPanel`'s `activityEvents` prop
   (`src/components/features/feature-ide-docs-panel.tsx`).

The backend scoping capability already exists and is already exercised by tests
(`TestListActivity_WorkspaceLevel_ReturnsEvents`,
`TestActivityFilterClauseMatchesWorkflowNamesAndUUIDs`,
`TestListActivityEventsUsesIndependentActivityFilterClause` in
`internal/database/queries_test.go` / `internal/integration/workspace_integration_test.go`).
No other caller of `GET /workspaces/:id/activity` exists in the indexed repos
(`workflow-mcp`, `hermes-agent` — confirmed via GitNexus search, no matches).

## Constraints
- Backend behavior must not change: `featureId` stays optional on the endpoint
  (per product spec non-goals — a future workspace-wide Dashboard "recent
  activity" widget may need the unscoped call).
- `audience=client` label-allowlist behavior in `WorkspaceService.ListActivity`
  must be preserved unchanged.
- UI appearance/behavior of the Activity panel must not change — this is purely
  a data-fetching/caching efficiency fix.
- React Query cache key must become feature-scoped so switching between feature
  tabs does not serve stale cross-feature data from cache.

## Options Considered
### Option A — Pass `featureId` through `useActivity` and drop the client-side filter
Extend `listActivity`, `useActivity`, and the `workspaceKeys.activity` cache key to
accept `featureId`; update `FeatureWorkbench` to call `useActivity(workspaceId, featureId)`
and pass the (now already-scoped) `events` array straight to `FeatureIDEDocsPanel`,
removing the `featureEvents` filter/set-membership logic.
- Pros: Minimal, surgical diff; leverages backend capability that already exists
  and is already tested; fixes the network/O(n) filter cost described in the
  product spec; cache key correctly scopes per feature so tab-switching doesn't
  serve another feature's cached events.
- Cons: None significant — `useActivity` is called from exactly one place
  (`FeatureWorkbench`, confirmed via GitNexus `context` on `useActivity`), so the
  signature change has a blast radius of one call site.

### Option B — Keep `useActivity(workspaceId)` unscoped and just re-derive `featureEvents` more efficiently client-side (e.g. memoize)
- Pros: No signature/cache-key changes.
- Cons: Doesn't address the root problem — still fetches the entire workspace's
  activity log over the network on every feature-detail view; only avoids
  recomputation, not the fetch cost. Does not meet the product spec's goal
  ("must include that feature's ID so workflow-backend filters at the SQL
  layer").

## Chosen Design
**Option A.** Three files in `digital-factory-ui` change; no backend change.

1. **`src/services/workflow-backend/client.ts`** — `listActivity`:
   ```ts
   export async function listActivity(
     workspaceId: string,
     params?: { audience?: string; featureId?: string; taskId?: string; limit?: number },
   ): Promise<ActivityEvent[]> {
     const sp = new URLSearchParams();
     if (params?.audience) sp.set("audience", params.audience);
     if (params?.featureId) sp.set("featureId", params.featureId);
     if (params?.taskId) sp.set("taskId", params.taskId);
     if (params?.limit !== undefined) sp.set("limit", String(params.limit));
     const qs = sp.toString() ? `?${sp.toString()}` : "";
     return request<ActivityEvent[]>(`/api/workspaces/${workspaceId}/activity${qs}`);
   }
   ```
   `featureId` maps 1:1 onto the `featureId` query param already read by
   `WorkspaceHandler.ListActivity` (`c.Query("featureId")`). `taskId` is added for
   symmetry/future use per the product spec but is not wired from `useActivity` in
   this feature (non-goal).

2. **`src/constants/query-keys.ts`** — `workspaceKeys.activity`:
   ```ts
   activity: (workspaceId: string, featureId?: string): QueryKey =>
     ["workspace", workspaceId, "activity", "client", featureId ?? "all"] as const,
   ```
   Adding `featureId` (defaulted to `"all"` when absent) to the key means React
   Query caches feature-scoped activity independently per feature — switching
   feature tabs will not display another feature's cached events, and returning
   to a previously-open feature reuses that feature's own cache entry.

3. **`src/hooks/board/use-activity.ts`** — `useActivity`:
   ```ts
   export function useActivity(workspaceId: string | null, featureId: string | null): UseActivityResult {
     const { data, isLoading, error } = useQuery<ActivityEvent[], ApiError>({
       queryKey: workspaceId ? workspaceKeys.activity(workspaceId, featureId ?? undefined) : ["activity-disabled"],
       queryFn: () => listActivity(workspaceId!, { audience: "client", featureId: featureId ?? undefined }),
       enabled: workspaceId !== null,
       ...liveQueryOptions,
     });
     return { events: data ?? [], loading: isLoading, error: error ?? null };
   }
   ```
   Per the GitNexus call-graph, `useActivity` has exactly one caller
   (`FeatureWorkbench`), so this signature change is a contained, single-call-site
   update.

4. **`src/components/features/feature-workbench.tsx`** — `FeatureWorkbench`:
   - Change `const { events } = useActivity(workspaceId);` to
     `const { events } = useActivity(workspaceId, featureId);` (the component
     already receives `featureId` as a prop).
   - Remove the client-side `featureIds`/`activityTasksById`-based `.filter(...)`
     entirely — the server response is now already scoped to this feature (and,
     via `activityFilterClause`'s `feature_id = $N` match on
     `workspace_activity_events`, already includes that feature's task-scoped
     events too, since task activity rows carry the same `feature_id`).
   - Keep the existing `.sort((a, b) => (b.occurred_at ?? "").localeCompare(a.occurred_at ?? ""))`
     since the backend orders by `occurred_at DESC, sequence DESC` already but
     preserving the explicit client-side sort is harmless and keeps the diff
     minimal.
   - `activityTasksById`/`activityMembersByEmail` maps remain unchanged — they're
     used by `FeatureIDEDocsPanel` for rendering (task title lookups, avatar
     lookups), not for filtering, and are unaffected by this change.

No changes to `FeatureIDEDocsPanel` itself — it continues to receive an
`activityEvents` array as a prop; only the array's origin (now pre-filtered by
the backend) changes.

## Figma
Not applicable — no Figma links in the approved product spec (data-fetching
change only, no new UI).

## Dependency Analysis
- Single repo: `digital-factory-ui`. No `workflow-backend` change (confirmed the
  `featureId` filter path is already implemented and tested there).
- Three files touched, in dependency order: `client.ts` (leaf) →
  `query-keys.ts` (leaf) → `use-activity.ts` (depends on both) →
  `feature-workbench.tsx` (depends on `use-activity.ts`).
- `useActivity` has exactly one call site (`FeatureWorkbench`), confirmed via
  GitNexus `context`/`query` — no other component depends on its current
  two-argument-free signature, so this is a safe, contained breaking change
  within the same repo/PR.
- No database schema change, no new backend endpoint, no new dependency.

## Parallelization / Blocking Analysis
- All four edits are small and interdependent (signature threaded from
  `client.ts` up through `use-activity.ts` to `feature-workbench.tsx`), and all
  land in one repo — this is naturally a single task, not split across
  parallel workstreams.
- No other task/feature is blocked by this change and it blocks nothing else;
  it's an isolated frontend fix with no consumers outside the files listed
  above.
