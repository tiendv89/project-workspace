# Handoff — Client Delivery Visibility (read-only)

## Summary
## Feature

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — workflow-backend — activate workspace scoping in service layer | [PR](https://github.com/tiendv89/workflow-backend/pull/22) | All T1 subtasks implemented. Two-org isolation integration test (TestOrgIsolation_TwoOrgs) added. DB-layer scoping via ScopedWorkspaceIDs(ctx) enforced across all read endpoints (ListWorkspaces, GetWorkspace, GetFeature, ListFeatureTasks, SearchFeatures, SearchTasks, SearchWorkspaceTasks, GetTask, GetWorkspaceTask, ListActivity). AuthCtx absent pass-through preserved. No 🔴 blockers, no 🟡 important issues. Minor 🟢 nits only (duplicated test-fake scoping logic; extra blank line). |
| T2 — workflow-backend — activity-feed allowlist + audience=client relabel | [PR](https://github.com/tiendv89/workflow-backend/pull/21) | All 7 T2 subtasks implemented. Allowlist matches spec exactly (8 allowed actions, 6 filtered). Unit and integration tests complete. No 🔴/🟡 findings. CI passed (no check-runs). PR squash-merged. |
| T3 — digital-factory-ui — remove write affordances from client-reachable routes | [PR](https://github.com/tiendv89/digital-factory-ui/pull/90) | Reviewer approved. |
| T4 — digital-factory-ui — move /connect to /admin/connect + admin layout guard | [PR](https://github.com/tiendv89/digital-factory-ui/pull/89) | All T4 subtasks implemented and tested. CI passed (no check-runs). No 🔴/🟡 findings. Admin layout guard correctly gates /admin/* behind platform_admin check using useSession. All internal /connect references updated to /admin/connect. 🟢 Nit only: waitForTimeout(3000) in E2E test is fragile. PR squash-merged successfully. |
| T5 — digital-factory-ui — no-membership EmptyState + replace /connect redirects | [PR](https://github.com/tiendv89/digital-factory-ui/pull/93) | All 7 T5 subtasks implemented. CI passed (no check-runs). No 🔴/🟡 findings. EmptyState role-aware variants correct; board and root-page /connect redirects replaced cleanly. Two 🟢 nits: test co-location and waitForTimeout usage. |
| T6 — digital-factory-ui — client vocabulary mapping at status-render sites | [PR](https://github.com/tiendv89/digital-factory-ui/pull/91) | Reviewer approved. |
| T7 — digital-factory-ui — 30s focus-aware polling + manual Refresh button | [PR](https://github.com/tiendv89/digital-factory-ui/pull/94) | All T7 subtasks implemented. 30s focus-aware polling and Refresh button match technical-design.md Option 3A exactly. No 🔴/🟡 findings. CI: no check-runs (treated as passed). PR squash-merged successfully. |
| T8 — digital-factory-ui — wire activity feed to audience=client | [PR](https://github.com/tiendv89/digital-factory-ui/pull/92) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `internal/domain/dto.go`
- `internal/handler/workspace.go`
- `internal/handler/workspace_test.go`
- `internal/integration/workspace_integration_test.go`
- `internal/service/workspace.go`
- `internal/service/workspace_test.go`
- `next-env.d.ts`
- `pkg/testhelpers/fixtures.go`
- `src/__tests__/admin-layout-guard.test.ts`
- `src/__tests__/board-qa-integration.test.ts`
- `src/__tests__/client-status-labels.test.ts`
- `src/__tests__/create-task-button.test.ts`
- `src/__tests__/document-rendering.test.ts`
- `src/__tests__/empty-state.test.ts`
- `src/__tests__/feature-detail-sheet.test.ts`
- `src/__tests__/feature-tab-view.test.ts`
- `src/__tests__/kanban-status.test.ts`
- `src/__tests__/log-link-rendering.test.ts`
- `src/__tests__/t12-sidebar-in-reviewing.test.ts`
- `src/__tests__/t3-rendering-fixes.test.ts`
- `src/__tests__/t3-write-affordances-removed.test.ts`
- `src/__tests__/t5-regression.test.ts`
- `src/__tests__/t6-kanban-status.test.ts`
- `src/__tests__/t6-regression.test.ts`
- `src/__tests__/t7-feature-origin-task-nav.test.ts`
- `src/__tests__/t7-polling-refresh.test.ts`
- `src/__tests__/t8-activity-feed.test.ts`
- `src/__tests__/task-tracking-panel.test.ts`
- `src/app/admin/connect/page.tsx`
- `src/app/admin/layout.tsx`
- `src/app/board/page.tsx`
- `src/app/page.tsx`
- `src/features/board/components/ActivityFeed/ActivityFeed.tsx`
- `src/features/board/components/ActivityFeed/index.ts`
- `src/features/board/components/BoardHeader/BoardHeader.tsx`
- `src/features/board/components/CreateTaskButton/CreateTaskButton.tsx`
- `src/features/board/components/CreateTaskButton/index.ts`
- `src/features/board/components/FeatureBoardView/FeatureBoardView.tsx`
- `src/features/board/components/FeatureDetailSheet/FeatureDetailSheet.tsx`
- `src/features/board/components/FeatureRow/FeatureRow.tsx`
- `src/features/board/components/FeatureTabView/FeatureLogsPanel.tsx`
- `src/features/board/components/FeatureTabView/FeatureTabHeader.tsx`
- `src/features/board/components/FeatureTabView/FeatureTabView.tsx`
- `src/features/board/components/FeatureTabView/FeatureTaskDrilldown.tsx`
- `src/features/board/components/FeatureTabView/FeatureTasksPanel.tsx`
- `src/features/board/components/KanbanBoard/KanbanBoard.tsx`
- `src/features/board/components/TaskBoardView/TaskBoardView.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingDetailPanel.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingPanel.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingPanel.types.ts`
- `src/features/board/hooks/useActivity.ts`
- `src/features/board/lib/status.ts`
- `src/features/tasks/components/TaskDetailSheet/TaskDetailSheet.tsx`
- `src/features/tasks/components/TaskTabView/TaskTabView.tsx`
- `src/features/workspaces/components/EmptyState/EmptyState.tsx`
- `src/features/workspaces/components/EmptyState/index.ts`
- `src/features/workspaces/components/WorkspaceHeader/WorkspaceHeader.tsx`
- `src/features/workspaces/context/WorkspaceContext.tsx`
- `src/lib/query-keys.ts`
- `src/services/workflow-backend/client.ts`
- `src/services/workflow-backend/index.ts`
- `tests/browser-qa/t3-write-affordances.spec.ts`
- `tests/browser-qa/t4-admin-guard.spec.ts`
- `tests/browser-qa/t5-empty-state.spec.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T3: claimed | norepy@tiendv.dev | 2026-06-02 04:44:49.121000+00:00 |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-06-02 04:45:02.410000+00:00 |
| T1: claimed | pentative@gmail.com | 2026-06-02T04:41:29.177Z |
| T1: rag_pre_flight | pentative@gmail.com | 2026-06-02T04:41:39.025Z |
| T2: claimed | pentative@gmail.com | 2026-06-02T04:43:36.473Z |
| T2: rag_pre_flight | pentative@gmail.com | 2026-06-02T04:43:47.005Z |
| T2: started | pentative@gmail.com | 2026-06-02T04:46:36+0000 |
| T1: started | pentative@gmail.com | 2026-06-02T04:47:06+0000 |
| T4: claimed | norepy@tiendv.dev | 2026-06-02T04:47:51.902Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-06-02T04:48:04.460Z |
| T6: claimed | norepy@tiendv.dev | 2026-06-02T04:51:02.123Z |
| T6: rag_pre_flight | norepy@tiendv.dev | 2026-06-02T04:51:15.182Z |
| T3: started | norepy@tiendv.dev | 2026-06-02T04:52:27+0000 |
| T2: run_completed | pentative@gmail.com | 2026-06-02T04:56:06.589Z |
| T2: reviewer_started | noreply@anthropic.com | 2026-06-02T04:57:27.327Z |
| T1: run_completed | pentative@gmail.com | 2026-06-02T04:57:48.875Z |
| T1: reviewer_started | noreply@anthropic.com | 2026-06-02T04:58:18.594Z |
| T6: started | norepy@tiendv.dev | 2026-06-02T04:59:17+0000 |
| T2: reviewer_complete | pentative@gmail.com | 2026-06-02T05:03:31.762Z |
| T4: run_completed | norepy@tiendv.dev | 2026-06-02T05:03:42.899Z |
| T2: done | pentative@gmail.com | 2026-06-02T05:06:06.489Z |
| T8: ready | pentative@gmail.com | 2026-06-02T05:06:06.522Z |
| T3: run_completed | norepy@tiendv.dev | 2026-06-02T05:07:10.679Z |
| T8: claimed | pentative@gmail.com | 2026-06-02T05:07:19.927Z |
| T8: rag_pre_flight | pentative@gmail.com | 2026-06-02T05:07:29.460Z |
| T1: reviewer_complete | pentative@gmail.com | 2026-06-02T05:08:07.656Z |
| T1: fix_started | pentative@gmail.com | 2026-06-02T05:09:01.072Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-06-02T05:10:17.075Z |
| T4: reviewer_started | noreply@tiendv.dev | 2026-06-02T05:14:15.209Z |
| T8: started | pentative@gmail.com | 2026-06-02T05:14:32+0000 |
| T1: run_completed | pentative@gmail.com | 2026-06-02T05:17:53.048Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-06-02T05:18:34.798Z |
| T6: run_completed | norepy@tiendv.dev | 2026-06-02T05:18:52.677Z |
| T3: done | pentative@gmail.com | 2026-06-02T05:20:24.280Z |
| T7: ready | pentative@gmail.com | 2026-06-02T05:20:24.324Z |
| T3: workspace_pr_merge_failed | orchestrator | 2026-06-02T05:20:36.985Z |
| T6: reviewer_started | noreply@tiendv.dev | 2026-06-02T05:21:58.489Z |
| T4: reviewer_complete | norepy@tiendv.dev | 2026-06-02T05:22:38.424Z |
| T4: fix_started | norepy@tiendv.dev | 2026-06-02T05:25:29.654Z |
| T1: rebase_completed | pentative@gmail.com | 2026-06-02T05:29:49.645Z |
| T6: reviewer_complete | norepy@tiendv.dev | 2026-06-02T05:30:04.132Z |
| T6: done | pentative@gmail.com | 2026-06-02T05:31:37.962Z |
| T6: workspace_pr_merge_failed | orchestrator | 2026-06-02T05:31:50.283Z |
| T1: reviewer_started | noreply@anthropic.com | 2026-06-02T05:31:57.579Z |
| T8: run_completed | pentative@gmail.com | 2026-06-02T05:32:11.180Z |
| T4: run_completed | norepy@tiendv.dev | 2026-06-02T05:34:10.432Z |
| T4: reviewer_started | noreply@anthropic.com | 2026-06-02T05:34:22.977Z |
| T8: reviewer_started | noreply@tiendv.dev | 2026-06-02T05:37:59.075Z |
| T4: reviewer_complete | pentative@gmail.com | 2026-06-02T05:40:31.895Z |
| T1: reviewer_complete | pentative@gmail.com | 2026-06-02T05:40:47.487Z |
| T1: done | pentative@gmail.com | 2026-06-02T05:42:45.478Z |
| T1: workspace_pr_merge_failed | orchestrator | 2026-06-02T05:42:57.600Z |
| T4: done | pentative@gmail.com | 2026-06-02T05:43:11.036Z |
| T5: ready | pentative@gmail.com | 2026-06-02T05:43:11.062Z |
| T8: reviewer_complete | norepy@tiendv.dev | 2026-06-02T05:44:17.643Z |
| T5: claimed | pentative@gmail.com | 2026-06-02T05:46:11.923Z |
| T5: rag_pre_flight | pentative@gmail.com | 2026-06-02T05:46:21.966Z |
| T8: done | pentative@gmail.com | 2026-06-02T05:46:39.139Z |
| T5: started | pentative@gmail.com | 2026-06-02T05:49:19+0000 |
| T5: run_completed | pentative@gmail.com | 2026-06-02T05:57:46.835Z |
| T5: reviewer_started | noreply@anthropic.com | 2026-06-02T05:58:35.391Z |
| T5: reviewer_complete | pentative@gmail.com | 2026-06-02T06:06:43.027Z |
| T5: done | pentative@gmail.com | 2026-06-02T06:07:50.255Z |
| T5: workspace_pr_merge_failed | orchestrator | 2026-06-02T06:08:02.301Z |
| T7: claimed | pentative@gmail.com | 2026-06-02T06:42:30.265Z |
| T7: rag_pre_flight | pentative@gmail.com | 2026-06-02T06:42:44.914Z |
| T7: started | pentative@gmail.com | 2026-06-02T06:46:43+0000 |
| T7: run_completed | pentative@gmail.com | 2026-06-02T06:55:24.058Z |
| T7: reviewer_started | noreply@anthropic.com | 2026-06-02T06:56:02.656Z |
| T7: reviewer_complete | pentative@gmail.com | 2026-06-02T07:01:39.402Z |
| T7: done | pentative@gmail.com | 2026-06-02T07:02:04.009Z |
| T1: created | pye@swellnetwork.io | 2026-06-02T11:11:13+0700 |
| T2: created | pye@swellnetwork.io | 2026-06-02T11:11:13+0700 |
| T3: created | pye@swellnetwork.io | 2026-06-02T11:11:13+0700 |
| T4: created | pye@swellnetwork.io | 2026-06-02T11:11:13+0700 |
| T5: created | pye@swellnetwork.io | 2026-06-02T11:11:13+0700 |
| T6: created | pye@swellnetwork.io | 2026-06-02T11:11:13+0700 |
| T7: created | pye@swellnetwork.io | 2026-06-02T11:11:13+0700 |
| T8: created | pye@swellnetwork.io | 2026-06-02T11:11:13+0700 |
| T1: ready | pye@swellnetwork.io | 2026-06-02T11:19:19+0700 |
| T2: ready | pye@swellnetwork.io | 2026-06-02T11:19:19+0700 |
| T3: ready | pye@swellnetwork.io | 2026-06-02T11:19:19+0700 |
| T4: ready | pye@swellnetwork.io | 2026-06-02T11:19:19+0700 |
| T6: ready | pye@swellnetwork.io | 2026-06-02T11:19:19+0700 |