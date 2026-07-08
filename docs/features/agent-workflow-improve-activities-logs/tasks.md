
# Tasks — feature-scoped activity log fetch

## Dependency diagram
```
T1
```

## Index

| ID | Title | Repo | Depends On | Actor |
|----|-------|------|------------|-------|
| T1 | Thread featureId through activity fetch and drop client-side filter | digital-factory-ui | | agent |

## T1 — Thread featureId through activity fetch and drop client-side filter

### Description
Implement the chosen design from the technical design doc: make the Feature
workbench's activity fetch pass `featureId` to `workflow-backend`'s
`GET /api/workspaces/:workspaceId/activity` endpoint (which already supports
this filter server-side — no backend change needed), scope the React Query
cache key per feature, and remove the now-redundant client-side filtering in
`FeatureWorkbench`.

Changes, in dependency order:

1. **`src/services/workflow-backend/client.ts`** — extend `listActivity` to
   accept and serialize an optional `featureId` (and `taskId`, for symmetry)
   into the query string alongside `audience`.
2. **`src/constants/query-keys.ts`** — extend `workspaceKeys.activity` to take
   an optional `featureId` and include it in the returned query key (default
   to `"all"` when absent) so cached activity is scoped per feature, not just
   per workspace.
3. **`src/hooks/board/use-activity.ts`** — extend `useActivity` to accept a
   `featureId: string | null` second parameter; pass it into both the
   `queryKey` (via the updated `workspaceKeys.activity`) and the `listActivity`
   call's `featureId` param.
4. **`src/components/features/feature-workbench.tsx`** — update the
   `useActivity(workspaceId)` call site to `useActivity(workspaceId, featureId)`
   (the component already has `featureId` as a prop). Remove the client-side
   `featureIds` set / `featureEvents` filter logic entirely (the
   `.filter((e) => (e.feature_id ? featureIds.has(e.feature_id) : false) || ...)`
   block) since the backend response is now already scoped to this feature.
   Pass the hook's `events` directly to `FeatureIDEDocsPanel`'s
   `activityEvents` prop, keeping the existing `.sort(...)` by `occurred_at`
   for defense-in-depth ordering. Leave `activityTasksById` /
   `activityMembersByEmail` untouched — they're used for rendering lookups,
   not filtering.

Do not modify `workflow-backend` (Go) — the `featureId`/`taskId` filter already
exists and is already tested there; this task is frontend-only.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Update `listActivity` in `client.ts` to accept/serialize `featureId` (and `taskId`)
- [ ] Update `workspaceKeys.activity` in `query-keys.ts` to include `featureId` in the cache key
- [ ] Update `useActivity` in `use-activity.ts` to accept and thread through `featureId`
- [ ] Update `FeatureWorkbench` call site to pass `featureId` to `useActivity`
- [ ] Remove the client-side `featureEvents` filter block in `FeatureWorkbench`; pass `events` straight through
- [ ] Run full frontend test suite and typecheck (`npx tsc --noEmit`); update/add tests covering the new `featureId`-scoped query key and hook signature if existing tests assert on the old signature
- [ ] Verify no other caller of `useActivity` or `workspaceKeys.activity` exists that would break from the signature change (already confirmed via GitNexus: single call site)
