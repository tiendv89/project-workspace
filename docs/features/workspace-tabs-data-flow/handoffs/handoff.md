# Handoff — Workspace Tabs and Backend API Data Flow

## Summary
## Feature

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Frontend API client and shared workflow DTOs | [PR](https://github.com/tiendv89/digital-factory-ui/pull/41) | 🟡 Missing identifier helpers — T1 deliverable 'Define backend identifier helpers for workspaceId, featureId, taskId, feature_name, and task_name' is absent from all PR files (types.ts, client.ts, query-params.ts, index.ts). Fix: add type aliases WorkspaceId, FeatureId, TaskId to types.ts and re-export from index.ts. |
| T2 — Workspace switcher, import modal, and board bootstrap integration | [PR](https://github.com/tiendv89/digital-factory-ui/pull/42) | — |
| T3 — Workspace search, filters, refresh, and stale-source UX | [PR](https://github.com/tiendv89/digital-factory-ui/pull/43) | Human reset to change_requested — fix agent (cycle 3) crashed before completing. Outstanding issue: task search sends dual task_id+title params from single search input (KanbanBoard.context.tsx:130-131); fix only task_id from task-mode search box. |
| T4 — Task quick views, workspace-scoped task drawer, and task tab | [PR](https://github.com/tiendv89/digital-factory-ui/pull/44) | 🔴 closeTaskTab logic error (src/features/workspaces/context/WorkspaceContext.tsx): setActiveSurface unconditionally returns 'board' when closing any task tab on the task-tab surface, regardless of whether the closed tab is the active tab. With multiple tabs open, closing a non-active tab incorrectly navigates the user to the board. Fix: check activeTaskTabId === taskId before resetting activeSurface. |
| T5 — Feature mode, feature tab, and feature-scoped task drilldown | [PR](https://github.com/tiendv89/digital-factory-ui/pull/45) | 🟡 Drilldown tests misleadingly named and do not test FeatureTaskDrilldown states (src/__tests__/feature-tab-view.test.ts:645,677). T5 spec requires 'tests for drilldown and back behavior' — neither the loading state, error state, content rendering, nor data-back-to-feature affordance are verified. All other T5 deliverables implemented; 618 tests pass; typecheck clean. |
| T6 — Document rendering, source state, and copy affordances | [PR](https://github.com/tiendv89/digital-factory-ui/pull/46) | — |
| T7 — End-to-end browser QA and regression coverage | [PR](https://github.com/tiendv89/digital-factory-ui/pull/47) | 🔴 Subtask 'Capture browser QA notes or screenshots for the key surfaces' (tasks.md) not implemented — no browser QA notes or screenshots present in the PR. 🟡 Sections 9 and 12 test inline logic rather than importing production ImportModal/tab-management code — actual click/double-click/context-menu and tab-rendering production paths are untested. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `docs/workspace-tabs-qa-notes.md`
- `src/__tests__/document-rendering.test.ts`
- `src/__tests__/feature-tab-view.test.ts`
- `src/__tests__/query-params.test.ts`
- `src/__tests__/stale-state.test.ts`
- `src/__tests__/t7-end-to-end-qa.test.ts`
- `src/__tests__/task-board-view-wiring.test.ts`
- `src/__tests__/task-detail-sheet.test.ts`
- `src/__tests__/task-tab-view.test.ts`
- `src/__tests__/workflow-backend-client.test.ts`
- `src/__tests__/workflow-backend-query-params.test.ts`
- `src/__tests__/workspace-adapter.test.ts`
- `src/__tests__/workspace-bootstrap.test.ts`
- `src/app/board/page.tsx`
- `src/app/page.tsx`
- `src/app/providers/AppProviders.tsx`
- `src/features/board/components/BoardHeader/BoardHeader.tsx`
- `src/features/board/components/ErrorStates/AccessDeniedState.tsx`
- `src/features/board/components/ErrorStates/EmptyBoardState.tsx`
- `src/features/board/components/ErrorStates/NetworkErrorState.tsx`
- `src/features/board/components/FeatureBoardView/FeatureBoardView.tsx`
- `src/features/board/components/FeatureBoardView/FeatureListRow.tsx`
- `src/features/board/components/FeatureRow/FeatureRow.tsx`
- `src/features/board/components/FeatureTabView/FeatureTabView.tsx`
- `src/features/board/components/FeatureTabView/index.ts`
- `src/features/board/components/KanbanBoard/KanbanBoard.context.tsx`
- `src/features/board/components/KanbanBoard/KanbanBoard.tsx`
- `src/features/board/components/TaskBoardView/TaskBoardView.tsx`
- `src/features/board/components/TaskCard/TaskCard.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingItem.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingPanel.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingSection.tsx`
- `src/features/board/hooks/useBackendFeatureSearch.ts`
- `src/features/board/hooks/useBackendTaskSearch.ts`
- `src/features/board/hooks/useBoardData.ts`
- `src/features/board/hooks/useFeatureDetail.ts`
- `src/features/board/hooks/usePullRequestTaskData.ts`
- `src/features/board/hooks/useSidebarTasks.ts`
- `src/features/board/lib/error-utils.ts`
- `src/features/board/types.ts`
- `src/features/tasks/components/TaskDetailSheet/TaskDetailSheetMount.tsx`
- `src/features/tasks/components/TaskTabView/TaskTabView.tsx`
- `src/features/tasks/components/TaskTabView/index.ts`
- `src/features/tasks/hooks/useWorkspaceTask.ts`
- `src/features/tasks/index.ts`
- `src/features/workspaces/components/ImportModal/ImportModal.tsx`
- `src/features/workspaces/components/ImportModal/index.ts`
- `src/features/workspaces/components/WorkspaceSwitcher/WorkspaceSwitcher.tsx`
- `src/features/workspaces/components/WorkspaceSwitcher/index.ts`
- `src/features/workspaces/components/WorkspaceTabBar/WorkspaceTabBar.tsx`
- `src/features/workspaces/components/WorkspaceTabBar/index.ts`
- `src/features/workspaces/context/WorkspaceContext.tsx`
- `src/features/workspaces/lib/importError.ts`
- `src/features/workspaces/lib/tabState.ts`
- `src/features/workspaces/lib/workspaceAdapter.ts`
- `src/lib/markdown.tsx`
- `src/services/local-workspace-store.ts`
- `src/services/workflow-backend/client.ts`
- `src/services/workflow-backend/index.ts`
- `src/services/workflow-backend/query-params.ts`
- `src/services/workflow-backend/types.ts`
- `src/services/yaml-parser.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T2: revised | minhkienn203@gmail.com | 2026-05-20 07:11:39+00:00 |
| T2: revised | minhkienn203@gmail.com | 2026-05-20 11:34:28+07:00 |
| T1: revised | minhkienn203@gmail.com | 2026-05-20T04:34:28.000Z |
| T3: revised | minhkienn203@gmail.com | 2026-05-20T04:34:28.000Z |
| T4: revised | minhkienn203@gmail.com | 2026-05-20T04:34:28.000Z |
| T5: revised | minhkienn203@gmail.com | 2026-05-20T04:34:28.000Z |
| T6: revised | minhkienn203@gmail.com | 2026-05-20T04:34:28.000Z |
| T1: ready | minhkienn203@gmail.com | 2026-05-20T05:46:30.000Z |
| T1: reset | minhkienn203@gmail.com | 2026-05-20T07:11:39.000Z |
| T1: ready | minhkienn203@gmail.com | 2026-05-20T07:27:38.000Z |
| T7: revised | minhkienn203@gmail.com | 2026-05-20T11:34:28+07:00 |
| T2: ready | norepy@tiendv.dev | 2026-05-21 09:08:00.327000+00:00 |
| T2: claimed | norepy@tiendv.dev | 2026-05-21 09:09:32.086000+00:00 |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-21 09:09:44.367000+00:00 |
| T2: claimed | norepy@tiendv.dev | 2026-05-21 11:39:52.100000+00:00 |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-21 11:40:00.939000+00:00 |
| T1: claimed | norepy@tiendv.dev | 2026-05-21T08:36:56.714Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T08:37:12.591Z |
| T1: started | norepy@tiendv.dev | 2026-05-21T08:41:10+0000 |
| T1: run_completed | norepy@tiendv.dev | 2026-05-21T08:48:34.341Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-21T08:50:26.800Z |
| T1: reviewer_complete | norepy@tiendv.dev | 2026-05-21T08:57:43.285Z |
| T1: fix_started | norepy@tiendv.dev | 2026-05-21T08:58:47.835Z |
| T1: run_completed | norepy@tiendv.dev | 2026-05-21T09:04:09.635Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-21T09:04:53.598Z |
| T1: done | norepy@tiendv.dev | 2026-05-21T09:07:59.995Z |
| T2: started | norepy@tiendv.dev | 2026-05-21T09:16:42+0000 |
| T2: started | norepy@tiendv.dev | 2026-05-21T11:46:14+0000 |
| T2: run_completed | norepy@tiendv.dev | 2026-05-21T11:58:03.657Z |
| T2: reviewer_started | noreply@tiendv.dev | 2026-05-21T12:00:10.795Z |
| T2: done | norepy@tiendv.dev | 2026-05-21T12:07:12.944Z |
| T3: ready | norepy@tiendv.dev | 2026-05-21T12:07:13.350Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-21T12:08:01.405Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T12:08:16.259Z |
| T3: started | norepy@tiendv.dev | 2026-05-21T12:16:15+0000 |
| T3: retried | norepy@tiendv.dev | 2026-05-21T12:31:33.764Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-21T12:33:07.117Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T12:33:13.365Z |
| T3: started | norepy@tiendv.dev | 2026-05-21T12:40:02+0000 |
| T3: run_completed | norepy@tiendv.dev | 2026-05-21T12:47:39.466Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-21T12:48:25.604Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-21T12:58:33.598Z |
| T3: fix_started | norepy@tiendv.dev | 2026-05-21T13:00:03.399Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-21T13:05:19.061Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-21T13:07:08.910Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-21T13:16:56.352Z |
| T3: fix_started | norepy@tiendv.dev | 2026-05-21T13:18:37.566Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-21T13:26:59.106Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-21T13:27:53.092Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-21T13:41:14.504Z |
| T3: fix_started | norepy@tiendv.dev | 2026-05-21T13:42:57.713Z |
| T3: fix_started | norepy@tiendv.dev | 2026-05-21T14:55:39.776Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-21T15:01:35.890Z |
| T3: done | norepy@tiendv.dev | 2026-05-21T16:01:13.422Z |
| T4: ready | norepy@tiendv.dev | 2026-05-21T16:01:13.767Z |
| T5: ready | norepy@tiendv.dev | 2026-05-21T16:01:13.770Z |
| T4: claimed | norepy@tiendv.dev | 2026-05-21T16:03:16.046Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T16:03:29.344Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-21T16:03:35.625Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T16:03:48.145Z |
| T4: started | norepy@tiendv.dev | 2026-05-21T16:10:31+0000 |
| T5: started | norepy@tiendv.dev | 2026-05-21T16:12:15+0000 |
| T4: retried | norepy@tiendv.dev | 2026-05-21T16:19:41.857Z |
| T4: claimed | norepy@tiendv.dev | 2026-05-21T16:21:12.566Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T16:21:18.873Z |
| T4: started | norepy@tiendv.dev | 2026-05-21T16:25:52+0000 |
| T4: run_completed | norepy@tiendv.dev | 2026-05-21T16:33:13.353Z |
| T4: reviewer_started | noreply@tiendv.dev | 2026-05-21T16:35:02.852Z |
| T4: reviewer_complete | norepy@tiendv.dev | 2026-05-21T16:42:54.026Z |
| T4: fix_started | norepy@tiendv.dev | 2026-05-21T16:44:29.377Z |
| T4: run_completed | norepy@tiendv.dev | 2026-05-21T16:49:37.817Z |
| T4: reviewer_started | noreply@tiendv.dev | 2026-05-21T16:51:27.272Z |
| T4: done | norepy@tiendv.dev | 2026-05-21T16:59:56.462Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-21T17:16:25.524Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T17:16:32.352Z |
| T5: retried | norepy@tiendv.dev | 2026-05-21T17:37:15.808Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-21T17:38:48.127Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T17:38:54.173Z |
| T5: started | norepy@tiendv.dev | 2026-05-21T17:45:25+0000 |
| T5: run_completed | norepy@tiendv.dev | 2026-05-21T17:48:58.832Z |
| T5: reviewer_started | noreply@tiendv.dev | 2026-05-21T17:50:27.963Z |
| T5: reviewer_complete | norepy@tiendv.dev | 2026-05-21T18:02:12.553Z |
| T5: fix_started | norepy@tiendv.dev | 2026-05-21T18:03:29.655Z |
| T5: run_completed | norepy@tiendv.dev | 2026-05-21T18:10:50.351Z |
| T5: reviewer_started | noreply@tiendv.dev | 2026-05-21T18:12:40.865Z |
| T5: done | norepy@tiendv.dev | 2026-05-21T18:18:38.124Z |
| T6: ready | norepy@tiendv.dev | 2026-05-21T18:18:38.489Z |
| T6: claimed | norepy@tiendv.dev | 2026-05-21T18:19:37.484Z |
| T6: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T18:19:50.281Z |
| T6: started | norepy@tiendv.dev | 2026-05-21T18:27:28+0000 |
| T6: run_completed | norepy@tiendv.dev | 2026-05-21T18:36:14.065Z |
| T6: reviewer_started | noreply@tiendv.dev | 2026-05-21T18:37:00.091Z |
| T2: ready | matthew@swellnetwork.io | 2026-05-21T18:37:42+0700 |
| T6: done | norepy@tiendv.dev | 2026-05-21T18:43:27.300Z |
| T7: ready | norepy@tiendv.dev | 2026-05-21T18:43:27.681Z |
| T7: claimed | norepy@tiendv.dev | 2026-05-21T18:44:29.979Z |
| T7: rag_pre_flight | norepy@tiendv.dev | 2026-05-21T18:44:42.270Z |
| T7: started | norepy@tiendv.dev | 2026-05-21T18:49:04+0000 |
| T7: run_completed | norepy@tiendv.dev | 2026-05-21T19:00:27.879Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-21T19:01:49.018Z |
| T7: reviewer_complete | norepy@tiendv.dev | 2026-05-21T19:08:13.754Z |
| T7: fix_started | norepy@tiendv.dev | 2026-05-21T19:09:14.425Z |
| T7: run_completed | norepy@tiendv.dev | 2026-05-21T19:17:56.358Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-21T19:18:42.492Z |
| T7: done | norepy@tiendv.dev | 2026-05-21T19:25:04.596Z |
| T3: reviewer_complete | matthew@swellnetwork.io | 2026-05-21T21:52:56+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-22T00:12:45+0700 |