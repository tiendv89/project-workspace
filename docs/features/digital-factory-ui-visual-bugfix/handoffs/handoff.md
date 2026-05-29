# Handoff — Digital Factory UI Visual Bug Fix

## Summary
## Feature

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Frontend API cache foundation | [PR](https://github.com/tiendv89/digital-factory-ui/pull/71) | All 7 T1 subtasks implemented. 5-minute stale time configured, refetchOnWindowFocus disabled, all query-key helpers present with param normalization. Tests comprehensive. No 🔴/🟡 findings. Two 🟢 nits only: gcTime equals staleTime (query-client.ts:12) and sidebarTasks URLSearchParams not sorted (query-keys.ts:43). requires_human_review=true — merge deferred to human. |
| T2 — Board/sidebar/mode query cache migration | [PR](https://github.com/tiendv89/digital-factory-ui/pull/76) | All T2 subtasks implemented: useBoardData, useSidebarTasks, useBackendTaskSearch, useBackendFeatureSearch migrated to TanStack Query. usePullRequestTaskData inherits cache via useSidebarTasks delegation. 60-second auto-refresh correctly uses query invalidation+refetch without loading reset. Workspace sync invalidates cache in WorkspaceContext. CI: no check-runs. No 🔴/🟡 findings. Nits: debounce removed from search hooks; test wrapper anti-pattern in workspace-switch-provider.test.ts. |
| T3 — Task/feature tab detail query cache migration | [PR](https://github.com/tiendv89/digital-factory-ui/pull/75) | All T3 subtasks implemented. CI passed (no check runs). All three hooks (useWorkspaceTask, useFeatureDetail, useFeatureTask) migrated to TanStack Query with workspace-scoped keys matching the technical design. Cache pre-seeding tests prove tab revisit avoids loading waits within 5-minute window. Cross-workspace isolation verified. No 🔴/🟡 findings. |
| T4 — Board visual cleanup and In Reviewing status | [PR](https://github.com/tiendv89/digital-factory-ui/pull/72) | All T4 subtasks implemented. CI passed (docker: success). All 1220 tests pass. Lint clean (0 errors). No 🔴/🟡 findings. CreateTaskButton removed from board, in_reviewing added to STATUS_COLUMNS with label/color, FEATURE_STATUS_OPTIONS correctly excludes in_reviewing, render tests added. |
| T5 — Log link formatting | [PR](https://github.com/tiendv89/digital-factory-ui/pull/70) | All T5 subtasks implemented. Regex-based tokenizer fix correctly preserves whitespace around URL tokens, resolving the cycle-1 rendering issue. Tests cover link rendering, surrounding text, plain text, malformed URLs, and multiple URLs per note. No 🔴/🟡 findings. CI: no check-runs (treated as passed). requires_human_review=true — merge skipped. |
| T6 — Regression tests and browser/network QA | [PR](https://github.com/tiendv89/digital-factory-ui/pull/81) | All 16 T6 subtasks covered across the full test suite. All 1390 tests pass. Lint clean (0 errors). Browser QA Playwright spec scaffolded (requires_human_review=true for live browser validation). No 🔴/🟡 findings. PR #81 created targeting feature/digital-factory-ui-visual-bugfix. |
| T7 — Feature-origin task tab navigation and tab flicker hardening | [PR](https://github.com/tiendv89/digital-factory-ui/pull/77) | 🟡 src/__tests__/t7-feature-origin-task-nav.test.ts — T7 subtask explicitly requires component tests for no blank/flicker tab switching; test file header acknowledges it ('Flicker hardening: loading stays false when cached data exists') but no such test is implemented. All other subtasks implemented correctly. CI passed, 1319/1319 tests pass, linter 0 errors. |
| T8 — Remove board sort controls | [PR](https://github.com/tiendv89/digital-factory-ui/pull/78) | All T8 subtasks implemented: SortSelector and dead sort wiring removed from KanbanBoard.tsx and KanbanBoard.context.tsx; default ordering preserved via BOARD_DEFAULT_SORT; tests cover sort absence in Feature Mode and Task Mode plus ordering regression. No 🔴/🟡 findings. CI has no check-runs (treated as passing). |
| T9 — Sidebar task last-updated timestamps | [PR](https://github.com/tiendv89/digital-factory-ui/pull/79) | All T9 subtasks implemented. CI has no check-runs (treated as passed). Previous lint issue (unused `tick` variable) correctly fixed — useLastUpdatedTimer() called without capturing return value. No 🔴/🟡 findings. One 🟢 nit: useLastUpdatedTimer return type could be void for clarity, but is intentional as designed. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `package.json`
- `pnpm-lock.yaml`
- `src/__tests__/feature-tab-view.test.ts`
- `src/__tests__/feature-task-docs-panel.test.ts`
- `src/__tests__/kanban-status.test.ts`
- `src/__tests__/log-link-rendering.test.ts`
- `src/__tests__/query-client.test.ts`
- `src/__tests__/query-keys.test.ts`
- `src/__tests__/t2-board-cache-migration.test.ts`
- `src/__tests__/t3-cache-migration.test.ts`
- `src/__tests__/t4-board-cleanup-in-reviewing.test.ts`
- `src/__tests__/t6-regression.test.ts`
- `src/__tests__/t6-server-integration.test.ts`
- `src/__tests__/t7-feature-origin-task-nav.test.ts`
- `src/__tests__/t7-provider-close-task-tab.test.ts`
- `src/__tests__/t9-sidebar-last-updated.test.ts`
- `src/__tests__/time.test.ts`
- `src/__tests__/url-tokenizer.test.ts`
- `src/__tests__/workspace-switch-provider.test.ts`
- `src/app/providers/AppProviders.tsx`
- `src/app/test/board-qa/page.tsx`
- `src/features/board/components/FeatureTabView/FeatureLogsPanel.tsx`
- `src/features/board/components/FeatureTabView/FeatureTabView.tsx`
- `src/features/board/components/FeatureTabView/FeatureTasksPanel.tsx`
- `src/features/board/components/FeatureTabView/index.ts`
- `src/features/board/components/KanbanBoard/KanbanBoard.context.tsx`
- `src/features/board/components/KanbanBoard/KanbanBoard.tsx`
- `src/features/board/components/TaskTrackingPanel/TaskTrackingItem.tsx`
- `src/features/board/hooks/useBackendFeatureSearch.ts`
- `src/features/board/hooks/useBackendTaskSearch.ts`
- `src/features/board/hooks/useBoardData.ts`
- `src/features/board/hooks/useFeatureDetail.ts`
- `src/features/board/hooks/useLastUpdatedTimer.ts`
- `src/features/board/hooks/useSidebarTasks.ts`
- `src/features/board/lib/status.ts`
- `src/features/tasks/components/TaskTabView/TaskTabView.tsx`
- `src/features/tasks/hooks/useWorkspaceTask.ts`
- `src/features/workspaces/context/WorkspaceContext.tsx`
- `src/lib/query-client.ts`
- `src/lib/query-keys.ts`
- `src/lib/time.ts`
- `src/lib/url-tokenizer.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | unknown@local | 2026-05-28T07:14:20.000Z |
| T4: ready | unknown@local | 2026-05-28T07:14:20.000Z |
| T5: ready | unknown@local | 2026-05-28T07:14:20Z |
| T4: claimed | you@example.com | 2026-05-28T07:37:18.992Z |
| T4: rag_pre_flight | you@example.com | 2026-05-28T07:37:30.622Z |
| T1: claimed | pentative@gmail.com | 2026-05-28T07:38:08.344Z |
| T1: rag_pre_flight | pentative@gmail.com | 2026-05-28T07:38:19.097Z |
| T5: claimed | pentative@gmail.com | 2026-05-28T07:38:22.875Z |
| T5: rag_pre_flight | pentative@gmail.com | 2026-05-28T07:38:32.452Z |
| T5: started | pentative@gmail.com | 2026-05-28T07:41:20+0000 |
| T1: started | pentative@gmail.com | 2026-05-28T07:42:04+0000 |
| T5: run_completed | pentative@gmail.com | 2026-05-28T07:47:44.517Z |
| T5: reviewer_started | noreply@anthropic.com | 2026-05-28T07:48:51.037Z |
| T1: run_completed | pentative@gmail.com | 2026-05-28T07:49:06.759Z |
| T1: reviewer_started | noreply@anthropic.com | 2026-05-28T07:50:08.186Z |
| T4: blocked | you@example.com | 2026-05-28T07:51:22.086Z |
| T1: reviewer_complete | pentative@gmail.com | 2026-05-28T07:55:20.305Z |
| T5: reviewer_complete | pentative@gmail.com | 2026-05-28T07:58:05.760Z |
| T5: fix_started | pentative@gmail.com | 2026-05-28T07:59:28.655Z |
| T5: run_completed | pentative@gmail.com | 2026-05-28T08:08:48.308Z |
| T5: reviewer_started | reviewer@example.com | 2026-05-28T08:09:25.395Z |
| T4: claimed | pentative@gmail.com | 2026-05-28T08:10:31.613Z |
| T4: rag_pre_flight | pentative@gmail.com | 2026-05-28T08:10:36.629Z |
| T5: reviewer_complete | minhkienn203@gmail.com | 2026-05-28T08:11:36.057Z |
| T4: started | pentative@gmail.com | 2026-05-28T08:15:17+0000 |
| T4: run_completed | pentative@gmail.com | 2026-05-28T08:21:44.180Z |
| T4: reviewer_started | noreply@anthropic.com | 2026-05-28T08:22:18.018Z |
| T4: reviewer_complete | pentative@gmail.com | 2026-05-28T08:30:08.734Z |
| T5: reviewer_started | noreply@anthropic.com | 2026-05-28T08:55:50.096Z |
| T5: reviewer_complete | pentative@gmail.com | 2026-05-28T09:01:00.362Z |
| T4: done | pentative@gmail.com | 2026-05-28T09:08:38.486Z |
| T5: done | pentative@gmail.com | 2026-05-28T10:30:10.213Z |
| T5: workspace_pr_merge_failed | orchestrator | 2026-05-28T10:30:22.906Z |
| T1: done | pentative@gmail.com | 2026-05-28T10:45:15.112Z |
| T2: ready | pentative@gmail.com | 2026-05-28T10:45:15.156Z |
| T3: ready | pentative@gmail.com | 2026-05-28T10:45:15.157Z |
| T2: claimed | pentative@gmail.com | 2026-05-28T10:47:56.532Z |
| T2: rag_pre_flight | pentative@gmail.com | 2026-05-28T10:48:07.861Z |
| T3: claimed | pentative@gmail.com | 2026-05-28T10:48:10.922Z |
| T3: rag_pre_flight | pentative@gmail.com | 2026-05-28T10:48:21.423Z |
| T2: started | pentative@gmail.com | 2026-05-28T10:52:07+0000 |
| T3: started | pentative@gmail.com | 2026-05-28T10:52:25+0000 |
| T3: run_completed | pentative@gmail.com | 2026-05-28T10:59:34.702Z |
| T3: reviewer_started | noreply@anthropic.com | 2026-05-28T11:01:51.791Z |
| T2: run_completed | pentative@gmail.com | 2026-05-28T11:05:48.638Z |
| T2: reviewer_started | noreply@anthropic.com | 2026-05-28T11:06:30.082Z |
| T3: reviewer_complete | pentative@gmail.com | 2026-05-28T11:06:40.989Z |
| T2: reviewer_complete | pentative@gmail.com | 2026-05-28T11:14:12.365Z |
| T1: created | unknown@local | 2026-05-28T13:58:29+0700 |
| T2: created | unknown@local | 2026-05-28T13:58:29+0700 |
| T3: created | unknown@local | 2026-05-28T13:58:29+0700 |
| T4: created | unknown@local | 2026-05-28T13:58:29+0700 |
| T5: created | unknown@local | 2026-05-28T13:58:29+0700 |
| T6: created | unknown@local | 2026-05-28T13:58:29+0700 |
| T4: ready | unknown@local | 2026-05-28T15:09:04+0700 |
| T5: in_review | unknown@local | 2026-05-28T15:54:06+0700 |
| T6: revised | unknown@local | 2026-05-28T23:24:23+0700 |
| T7: created | unknown@local | 2026-05-28T23:24:23+0700 |
| T2: done | spiderbot@gmail.com | 2026-05-29T03:20:09.281Z |
| T2: workspace_pr_merge_failed | orchestrator | 2026-05-29T03:20:22.807Z |
| T3: done | spiderbot@gmail.com | 2026-05-29T03:20:37.953Z |
| T7: claimed | spiderbot@gmail.com | 2026-05-29T04:25:40.589Z |
| T7: rag_pre_flight | spiderbot@gmail.com | 2026-05-29T04:25:51.454Z |
| T7: run_completed | spiderbot@gmail.com | 2026-05-29T04:38:14.991Z |
| T7: reviewer_started | reviewer@example.com | 2026-05-29T04:40:20.591Z |
| T7: reviewer_complete | spiderbot@gmail.com | 2026-05-29T04:42:37.934Z |
| T8: claimed | norepy@tiendv.dev | 2026-05-29T06:16:00.449Z |
| T8: rag_pre_flight | norepy@tiendv.dev | 2026-05-29T06:16:17.455Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-29T06:23:24.634Z |
| T7: reviewer_complete | norepy@tiendv.dev | 2026-05-29T06:32:51.583Z |
| T7: fix_started | norepy@tiendv.dev | 2026-05-29T06:35:05.772Z |
| T8: run_completed | norepy@tiendv.dev | 2026-05-29T06:36:53.677Z |
| T8: reviewer_started | noreply@tiendv.dev | 2026-05-29T06:41:42.707Z |
| T8: reviewer_complete | norepy@tiendv.dev | 2026-05-29T06:50:38.155Z |
| T8: done | norepy@tiendv.dev | 2026-05-29T07:03:54.110Z |
| T7: run_completed | norepy@tiendv.dev | 2026-05-29T07:08:24.884Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-29T07:13:02.199Z |
| T7: reviewer_complete | norepy@tiendv.dev | 2026-05-29T07:29:18.176Z |
| T7: fix_started | norepy@tiendv.dev | 2026-05-29T07:32:08.525Z |
| T7: run_completed | norepy@tiendv.dev | 2026-05-29T07:43:05.411Z |
| T9: claimed | norepy@tiendv.dev | 2026-05-29T08:16:50.940Z |
| T9: rag_pre_flight | norepy@tiendv.dev | 2026-05-29T08:17:03.723Z |
| T7: done | norepy@tiendv.dev | 2026-05-29T08:20:20.899Z |
| T6: ready | norepy@tiendv.dev | 2026-05-29T08:20:21.300Z |
| T9: run_completed | norepy@tiendv.dev | 2026-05-29T08:30:46.602Z |
| T9: reviewer_started | noreply@tiendv.dev | 2026-05-29T08:32:38.719Z |
| T9: reviewer_complete | norepy@tiendv.dev | 2026-05-29T08:41:34.313Z |
| T9: fix_started | norepy@tiendv.dev | 2026-05-29T08:43:27.198Z |
| T9: run_completed | norepy@tiendv.dev | 2026-05-29T08:53:37.202Z |
| T9: reviewer_started | noreply@tiendv.dev | 2026-05-29T08:55:01.123Z |
| T9: reviewer_complete | norepy@tiendv.dev | 2026-05-29T09:01:58.725Z |
| T9: done | norepy@tiendv.dev | 2026-05-29T09:16:27.867Z |
| T6: claimed | spiderbot@gmail.com | 2026-05-29T09:47:04.305Z |
| T6: rag_pre_flight | spiderbot@gmail.com | 2026-05-29T09:47:15.153Z |
| T6: run_completed | spiderbot@gmail.com | 2026-05-29T09:58:30.500Z |
| T6: reviewer_started | noreply@tiendv.dev | 2026-05-29T09:59:43.586Z |
| T6: reviewer_complete | norepy@tiendv.dev | 2026-05-29T10:11:03.945Z |
| T7: ready | minhkienn203@gmail.com | 2026-05-29T11:21:51+0700 |
| T6: done | minhkienn203@gmail.com | 2026-05-29T11:48:11Z |
| T8: created | codex | 2026-05-29T13:06:52+0700 |
| T8: ready | codex | 2026-05-29T13:06:52+0700 |
| T7: in_review | minhkienn203@gmail.com | 2026-05-29T13:18:46+0700 |
| T9: created | codex | 2026-05-29T14:56:28+0700 |
| T9: ready | codex | 2026-05-29T14:56:28+0700 |
| T2: done | human | 2026-05-29T18:34:48+0700 |
| T5: done | human | 2026-05-29T18:34:48+0700 |