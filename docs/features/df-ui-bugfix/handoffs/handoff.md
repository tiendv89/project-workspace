# Handoff — DF UI Bug Fix

## Summary
## Feature - Feature ID: `df-ui-bugfix` - Title: DF UI Bug Fix — scoped follow-up - Implementation repo: `digital-factory-ui` - GitHub: https://github.com/tiendv89/digital-factory-ui

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Dedicated task creation flow and detail-modal cleanup | [PR](https://github.com/tiendv89/digital-factory-ui/pull/57) | 🟡 Missing test: task creation opens the dedicated flow (src/features/board/components/CreateTaskButton/CreateTaskButton.tsx). T1 subtask 5 requires focused tests proving task creation opens the dedicated flow — no test was added for the new CreateTaskButton component. All other T1 subtasks are correctly implemented. |
| T10 — Task tab layout reordering | [PR](https://github.com/tiendv89/digital-factory-ui/pull/63) | All 4 T10 subtasks implemented: PullRequestsSection moved to top, sections reordered to Pull Requests → Details → Execution → Last Updated → Activity Timeline, consistent border/spacing styling maintained, render test added and verifies correct order. No 🔴/🟡 findings. One 🟢 nit on test pattern inconsistency (non-blocking). |
| T11 — Workspace switching tab and state reset | [PR](https://github.com/tiendv89/digital-factory-ui/pull/66) | All 6 T11 subtasks implemented. Cycle-1 concern (missing behavioral integration test for selectWorkspace) resolved by workspace-switch-provider.test.ts using RTL renderHook. CI: no check-runs (treated as passed). No 🔴/🟡 findings. 💡 Nit only: workspace-switch-reset.test.ts:145 contains expect(true).toBe(true) — redundant placeholder. PR squash-merged successfully. |
| T12 — Sidebar in_reviewing collapsible section and list rendering | [PR](https://github.com/tiendv89/digital-factory-ui/pull/67) | All T12 subtasks implemented: TrackedStatus extended with in_reviewing, TRACKED_SECTIONS updated to 5 sections in correct order (blocked→in_progress→in_reviewing→in_review→ready), section initialized expanded, SIDEBAR_TASK_PARAMS updated, groupTasks.ts SIDEBAR_STATUSES updated. 14 new test cases added plus existing tests updated. 1175/1175 tests pass. No 🔴/🟡 findings. PR squash-merged. |
| T2 — Mode-specific list search/filter endpoint contract | [PR](https://github.com/tiendv89/digital-factory-ui/pull/58) | All T2 subtasks implemented. Feature mode and Task mode list/search/filter locked to mode-specific backend endpoints (/features and /tasks). Local client-side filtering removed from FeatureBoardView and TaskBoardView. Status-only filter correctly activates backend search. Query params serialize title and status correctly. Comprehensive tests added in t2-endpoint-contract.test.ts. No 🔴/🟡 findings. |
| T3 — Task Docs tasks.md document URL rendering | [PR](https://github.com/tiendv89/digital-factory-ui/pull/59) | All T3 subtasks implemented. 924/924 tests pass. No 🔴/🟡 findings. Key changes: document_type 'tasks' → 'tasks_md' selection fixed, mdError branch added, differentiated empty states (missing doc vs missing content), 22 new/updated tests cover all required scenarios. |
| T4 — Feature/task pagination API wiring | [PR](https://github.com/tiendv89/digital-factory-ui/pull/62) | All T4 subtasks implemented. 993/993 tests pass. No 🔴/🟡 findings. Sort and page-size state added to BoardContext; page-reset correctly wired for all filter/sort/limit changes; PageSizeSelector and SortSelector UI components added; shouldResetPage extended to include limit-change detection. |
| T5 — Task-mode feature lifecycle status mapping | [PR](https://github.com/tiendv89/digital-factory-ui/pull/60) | All T5 subtasks implemented. CI passed (no check runs). Zero red/yellow findings. deriveFeatureStatusFromTasks removed; normalizeFeatureLifecycleStatus gates all 8 valid feature lifecycle statuses; featureStatusMap threaded from context via useBackendTaskSearch; regression tests for all statuses and task-status rejection present. |
| T6 — Kanban feature lifecycle status mapping | [PR](https://github.com/tiendv89/digital-factory-ui/pull/61) | All 6 T6 subtasks implemented. CI passed (no check-runs). 1002/1002 tests pass. 0 lint errors. isValidFeatureStatus guard correctly filters Kanban columns to feature lifecycle statuses only. Task-status derivation removed from workspaceAdapter. No 🔴 or 🟡 findings. |
| T7 — Post-change final regression and browser QA | [PR](https://github.com/tiendv89/digital-factory-ui/pull/68) | All subtasks implemented. CI passed (no check-runs). Previous 🟡 findings (T7 subtask 6 cross-browser status-age indicator rendering and subtask 7 dynamic log-transition update) are now fully covered by the new src/__tests__/status-age-indicator-rendering.test.ts using @testing-library/react + jsdom with 555 lines of tests. No 🔴 or 🟡 findings remain. PR squash-merged successfully. |
| T8 — Sidebar blocked section and status-age indicators | [PR](https://github.com/tiendv89/digital-factory-ui/pull/65) | All 9 T8 subtasks implemented. computeStatusAge/formatStatusAgeDuration utilities correct with full fallback chain. Blocked section at top of sidebar. SIDEBAR_TASK_PARAMS includes blocked. Comprehensive test coverage (196 lines). No 🔴/🟡 findings. CI: no check-runs. PR squash-merged. |
| T9 — Timeline link formatting and click-handling | [PR](https://github.com/tiendv89/digital-factory-ui/pull/64) | All T9 subtasks implemented. CI passed (no check-runs). Regex-free tokenizer uses startsWith+URL constructor; target=_blank rel=noopener noreferrer present; 1139 tests passing; lint 0 errors. One 🟢 nit: array index as React key in TimelineNoteText. No 🔴/🟡 findings. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `package.json`
- `pnpm-lock.yaml`
- `src/__tests__/backend-list-params.test.ts`
- `src/__tests__/board-page-layout.test.ts`
- `src/__tests__/board-qa-integration.test.ts`
- `src/__tests__/create-task-button.test.ts`
- `src/__tests__/feature-detail-sheet.test.ts`
- `src/__tests__/feature-lifecycle-status.test.ts`
- `src/__tests__/feature-mode.test.ts`
- `src/__tests__/feature-tab-view.test.ts`
- `src/__tests__/feature-task-docs-panel.test.ts`
- `src/__tests__/group-tracked-tasks.test.ts`
- `src/__tests__/kanban-status.test.ts`
- `src/__tests__/load-board-data.test.ts`
- `src/__tests__/query-params.test.ts`
- `src/__tests__/react-performance-boundaries.test.ts`
- `src/__tests__/status-age-indicator-rendering.test.ts`
- `src/__tests__/status-filter-store.test.ts`
- `src/__tests__/t12-sidebar-in-reviewing.test.ts`
- `src/__tests__/t2-endpoint-contract.test.ts`
- `src/__tests__/t3-rendering-fixes.test.ts`
- `src/__tests__/t4-pagination-api.test.ts`
- `src/__tests__/t5-regression.test.ts`
- `src/__tests__/t6-kanban-status.test.ts`
- `src/__tests__/t6-regression.test.ts`
- `src/__tests__/t7-end-to-end-qa.test.ts`
- `src/__tests__/t8-sidebar-blocked-status-age.test.ts`
- `src/__tests__/task-detail-sheet.test.ts`
- `src/__tests__/task-tab-view.test.ts`
- `src/__tests__/task-tracking-panel.test.ts`
- `src/__tests__/url-tokenizer.test.ts`
- `src/__tests__/workflow-backend-query-params.test.ts`
- `src/__tests__/workspace-adapter.test.ts`
- `src/__tests__/workspace-switch-provider.test.ts`
- `src/__tests__/workspace-switch-reset.test.ts`
- `src/app/board/page.tsx`
- `src/app/test/board-qa/page.tsx`
- `src/features/board/components/CreateTaskButton/CreateTaskButton.tsx`
- `src/features/board/components/CreateTaskButton/index.ts`
- `src/features/board/components/FeatureBoardView/FeatureBoardView.tsx`
- `src/features/board/components/FeatureDetailSheet/FeatureDetailSheetMount.tsx`
- `src/features/board/components/FeatureDetailSheet/index.ts`
- `src/features/board/components/FeatureDetailSheet/index.tsx`
- `src/features/board/components/FeatureRow/FeatureRow.tsx`
- `src/features/board/components/FeatureTabView/FeatureTasksPanel.tsx`
- `src/features/board/components/KanbanBoard/KanbanBoard.context.tsx`
- `src/features/board/components/KanbanBoard/KanbanBoard.tsx`
- `src/features/board/components/KanbanBoard/index.tsx`
- `src/features/board/components/PaginationControls/PaginationControls.tsx`
- `src/features/board/components/PaginationControls/index.ts`
- `src/features/board/components/TaskBoardView/TaskBoardView.tsx`
- `src/features/board/components/TaskCard/TaskCard.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingDetailPanel.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingItem.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingPanel.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingPanel.types.ts`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingSection.tsx`
- `src/features/board/components/TaskTrackingPanel/groupTasks.ts`
- `src/features/board/data/load-board-data.ts`
- `src/features/board/hooks/useBackendTaskSearch.ts`
- `src/features/board/index.ts`
- `src/features/board/lib/backend-list-params.ts`
- `src/features/board/lib/status-filter-store.ts`
- `src/features/board/lib/status.ts`
- `src/features/tasks/components/TaskDetailSheet/TaskDetailSheet.tsx`
- `src/features/tasks/components/TaskDetailSheet/TaskDetailSheetMount.tsx`
- `src/features/tasks/components/TaskDetailSheet/index.tsx`
- `src/features/tasks/index.ts`
- `src/features/workspaces/context/WorkspaceContext.tsx`
- `src/features/workspaces/lib/workspaceAdapter.ts`
- `src/lib/time.ts`
- `src/lib/url-tokenizer.ts`
- `src/services/workflow-backend/query-params.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: claimed | norepy@tiendv.dev | 2026-05-26T10:03:48.469Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-26T10:04:03.324Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-26T10:04:07.065Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-26T10:04:21.429Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-26T10:22:24.243Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-26T10:22:41.960Z |
| T1: run_completed | norepy@tiendv.dev | 2026-05-26T10:23:48.391Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-26T10:24:07.655Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-26T10:24:24.913Z |
| T2: run_completed | norepy@tiendv.dev | 2026-05-26T10:25:20.124Z |
| T6: claimed | norepy@tiendv.dev | 2026-05-26T10:37:53.628Z |
| T6: rag_pre_flight | norepy@tiendv.dev | 2026-05-26T10:38:13.530Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-26T10:38:58.764Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-26T10:42:56.797Z |
| T5: run_completed | norepy@tiendv.dev | 2026-05-26T10:43:45.536Z |
| T2: reviewer_started | noreply@tiendv.dev | 2026-05-26T10:51:52.438Z |
| T1: reviewer_complete | norepy@tiendv.dev | 2026-05-26T10:52:52.498Z |
| T1: fix_started | norepy@tiendv.dev | 2026-05-26T10:54:45.097Z |
| T6: run_completed | norepy@tiendv.dev | 2026-05-26T10:55:44.274Z |
| T2: reviewer_complete | norepy@tiendv.dev | 2026-05-26T10:59:08.930Z |
| T2: done | norepy@tiendv.dev | 2026-05-26T11:08:29.411Z |
| T4: ready | norepy@tiendv.dev | 2026-05-26T11:08:29.939Z |
| T1: run_completed | norepy@tiendv.dev | 2026-05-26T11:09:53.159Z |
| T4: claimed | norepy@tiendv.dev | 2026-05-26T11:16:04.557Z |
| T6: rebase_completed | norepy@tiendv.dev | 2026-05-26T11:19:15.389Z |
| T1: rebase_completed | norepy@tiendv.dev | 2026-05-26T11:31:59.214Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-26T11:35:54.579Z |
| T5: rebase_completed | norepy@tiendv.dev | 2026-05-26T11:36:22.133Z |
| T1: reviewer_complete | noreply@tiendv.dev | 2026-05-26T11:39:48+0000 |
| T1: fix_started | norepy@tiendv.dev | 2026-05-26T11:42:51.889Z |
| T1: reviewer_complete | norepy@tiendv.dev | 2026-05-26T11:43:26.791Z |
| T1: fix_started | norepy@tiendv.dev | 2026-05-26T11:45:58.153Z |
| T6: rebase_completed | norepy@tiendv.dev | 2026-05-26T11:46:35.061Z |
| T1: run_completed | norepy@tiendv.dev | 2026-05-26T11:53:28.727Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-26T11:56:39.048Z |
| T1: run_completed | norepy@tiendv.dev | 2026-05-26T11:57:15.854Z |
| T1: done | norepy@tiendv.dev | 2026-05-26T12:02:56.429Z |
| T5: rebase_completed | norepy@tiendv.dev | 2026-05-26T12:03:53.805Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-26T12:06:22.352Z |
| T1: created | minhkienn203@gmail.com | 2026-05-26T12:22:09+0700 |
| T2: created | minhkienn203@gmail.com | 2026-05-26T12:22:09+0700 |
| T5: reviewer_started | noreply@tiendv.dev | 2026-05-26T12:36:47.853Z |
| T3: created | minhkienn203@gmail.com | 2026-05-26T12:42:20+0700 |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-26T12:43:19.176Z |
| T4: created | minhkienn203@gmail.com | 2026-05-26T12:49:23+0700 |
| T5: created | minhkienn203@gmail.com | 2026-05-26T13:01:58+0700 |
| T6: created | minhkienn203@gmail.com | 2026-05-26T13:05:26+0700 |
| T3: done | norepy@tiendv.dev | 2026-05-26T13:07:53.536Z |
| T7: created | minhkienn203@gmail.com | 2026-05-26T13:15:57+0700 |
| T1: ready | minhkienn203@gmail.com | 2026-05-26T16:21:43+0700 |
| T2: ready | minhkienn203@gmail.com | 2026-05-26T16:21:43+0700 |
| T3: ready | minhkienn203@gmail.com | 2026-05-26T16:21:43+0700 |
| T5: ready | minhkienn203@gmail.com | 2026-05-26T16:21:43+0700 |
| T6: ready | minhkienn203@gmail.com | 2026-05-26T16:21:43+0700 |
| T8: created | minhkienn203@gmail.com | 2026-05-26T18:43:49+0700 |
| T9: created | minhkienn203@gmail.com | 2026-05-26T19:06:05+0700 |
| T10: created | minhkienn203@gmail.com | 2026-05-26T19:09:34+0700 |
| T5: reviewer_started | noreply@anthropic.com | 2026-05-27T05:14:14.333Z |
| T6: reviewer_started | noreply@anthropic.com | 2026-05-27T06:25:44.194Z |
| T5: reviewer_complete | pentative@gmail.com | 2026-05-27T06:25:58.111Z |
| T4: claimed | norepy@tiendv.dev | 2026-05-27T06:27:12.946Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-27T06:27:19.366Z |
| T6: reviewer_complete | pentative@gmail.com | 2026-05-27T06:33:40.671Z |
| T4: run_completed | norepy@tiendv.dev | 2026-05-27T06:45:32.114Z |
| T4: reviewer_started | noreply@tiendv.dev | 2026-05-27T06:46:25.259Z |
| T4: reviewer_complete | norepy@tiendv.dev | 2026-05-27T06:56:06.974Z |
| T4: done | pentative@gmail.com | 2026-05-27T06:56:54.838Z |
| T4: workspace_pr_merge_failed | orchestrator | 2026-05-27T06:57:08.043Z |
| T6: done | pentative@gmail.com | 2026-05-27T07:55:57.678Z |
| T5: done | norepy@tiendv.dev | 2026-05-27T10:28:33.212Z |
| T4: done | pentative@gmail.com | 2026-05-27T10:33:55.304Z |
| T8: claimed | pentative@gmail.com | 2026-05-27T10:42:13.601Z |
| T8: rag_pre_flight | pentative@gmail.com | 2026-05-27T10:42:24.207Z |
| T9: claimed | pentative@gmail.com | 2026-05-27T10:42:28.219Z |
| T9: rag_pre_flight | pentative@gmail.com | 2026-05-27T10:42:37.801Z |
| T10: claimed | norepy@tiendv.dev | 2026-05-27T10:43:07.620Z |
| T10: rag_pre_flight | norepy@tiendv.dev | 2026-05-27T10:43:23.135Z |
| T11: claimed | norepy@tiendv.dev | 2026-05-27T10:43:53.411Z |
| T11: rag_pre_flight | norepy@tiendv.dev | 2026-05-27T10:44:11.000Z |
| T9: started | pentative@gmail.com | 2026-05-27T10:44:57+0000 |
| T8: started | pentative@gmail.com | 2026-05-27T10:47:46+0000 |
| T10: run_completed | norepy@tiendv.dev | 2026-05-27T11:03:28.007Z |
| T9: run_completed | pentative@gmail.com | 2026-05-27T11:03:43.372Z |
| T9: reviewer_started | noreply@anthropic.com | 2026-05-27T11:05:12.456Z |
| T8: run_completed | pentative@gmail.com | 2026-05-27T11:05:29.104Z |
| T10: reviewer_started | noreply@anthropic.com | 2026-05-27T11:05:37.877Z |
| T8: reviewer_started | noreply@tiendv.dev | 2026-05-27T11:07:06.582Z |
| T11: run_completed | norepy@tiendv.dev | 2026-05-27T11:07:44.914Z |
| T11: reviewer_started | noreply@tiendv.dev | 2026-05-27T11:10:36.060Z |
| T10: reviewer_complete | pentative@gmail.com | 2026-05-27T11:10:59.190Z |
| T9: reviewer_complete | pentative@gmail.com | 2026-05-27T11:11:42.748Z |
| T8: reviewer_complete | norepy@tiendv.dev | 2026-05-27T11:12:49.727Z |
| T11: reviewer_complete | norepy@tiendv.dev | 2026-05-27T11:17:19.418Z |
| T11: fix_started | pentative@gmail.com | 2026-05-27T11:17:59.195Z |
| T12: claimed | pentative@gmail.com | 2026-05-27T11:18:32.052Z |
| T12: rag_pre_flight | pentative@gmail.com | 2026-05-27T11:18:43.175Z |
| T10: done | norepy@tiendv.dev | 2026-05-27T11:19:33.964Z |
| T8: done | norepy@tiendv.dev | 2026-05-27T11:20:19.960Z |
| T9: done | norepy@tiendv.dev | 2026-05-27T11:21:07.222Z |
| T12: started | pentative@gmail.com | 2026-05-27T11:23:31+0000 |
| T12: run_completed | pentative@gmail.com | 2026-05-27T11:29:23.363Z |
| T11: run_completed | pentative@gmail.com | 2026-05-27T11:29:24.390Z |
| T11: reviewer_started | noreply@anthropic.com | 2026-05-27T11:31:20.123Z |
| T12: reviewer_started | noreply@anthropic.com | 2026-05-27T11:31:28.225Z |
| T5: ready | minhkienn203@gmail.com | 2026-05-27T12:12:24+0700 |
| T6: ready | minhkienn203@gmail.com | 2026-05-27T13:24:57+0700 |
| T4: ready | minhkienn203@gmail.com | 2026-05-27T13:25:48+0700 |
| T11: created | minhkienn203@gmail.com | 2026-05-27T14:30:00+0700 |
| T11: reviewer_complete | pentative@gmail.com | 2026-05-27T15:13:09.467Z |
| T12: reviewer_complete | pentative@gmail.com | 2026-05-27T15:26:29.835Z |
| T4: done | tiendv.52@gmai.com | 2026-05-27T17:32:52+0700 |
| T10: ready | tiendv.52@gmai.com | 2026-05-27T17:41:07+0700 |
| T11: ready | tiendv.52@gmai.com | 2026-05-27T17:41:07+0700 |
| T8: ready | tiendv.52@gmai.com | 2026-05-27T17:41:07+0700 |
| T9: ready | tiendv.52@gmai.com | 2026-05-27T17:41:07+0700 |
| T11: done | norepy@tiendv.dev | 2026-05-27T18:08:03.860Z |
| T12: done | norepy@tiendv.dev | 2026-05-27T18:08:46.136Z |
| T7: ready | norepy@tiendv.dev | 2026-05-27T18:08:47.099Z |
| T7: claimed | norepy@tiendv.dev | 2026-05-27T18:11:29.237Z |
| T7: rag_pre_flight | norepy@tiendv.dev | 2026-05-27T18:11:43.217Z |
| T12: created | minhkienn203@gmail.com | 2026-05-27T18:14:47+0700 |
| T12: ready | minhkienn203@gmail.com | 2026-05-27T18:14:47+0700 |
| T7: run_completed | norepy@tiendv.dev | 2026-05-27T18:35:13.563Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-27T18:37:27.885Z |
| T7: reviewer_complete | norepy@tiendv.dev | 2026-05-27T18:49:09.387Z |
| T7: fix_started | norepy@tiendv.dev | 2026-05-27T18:50:50.421Z |
| T7: run_completed | norepy@tiendv.dev | 2026-05-27T19:02:22.493Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-27T19:04:07.420Z |
| T7: reviewer_complete | norepy@tiendv.dev | 2026-05-27T19:11:51.096Z |
| T7: done | norepy@tiendv.dev | 2026-05-27T19:13:43.772Z |