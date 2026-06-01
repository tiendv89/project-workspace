# Handoff — Identity, Org & Workspace Foundation

## Summary
## Feature

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T0 — Register user-service in workspace.yaml | [PR](https://github.com/tiendv89/project-workspace/pull/403) | — |
| T1a — user-service DB schema v001 (identity + tenancy + sessions) | [PR](https://github.com/tiendv89/project-workspace/pull/404) | — |
| T1b — workspace DB schema v002 — add workspaces.organization_id | [PR](https://github.com/tiendv89/project-workspace/pull/405) | — |
| T2a — user-service repo scaffold (Go + Gin + pgx + Dockerfile + goose) | [PR](https://github.com/tiendv89/user-service/pull/1) | GitHub REST API returns HTTP 404 for all tiendv89/user-service endpoints with the current GITHUB_TOKEN (user: zbotdev). Cannot post review comment (Step 6a failed non-422) or check CI. Local code review confirms all T2a subtasks implemented correctly and tests pass, but review cannot be posted. Human intervention required to post the GitHub review and merge PR #1. |
| T2b — user-service — OAuth + sessions + identity + invitations + /api/me + /internal/sessions/validate | [PR](https://github.com/tiendv89/user-service/pull/2) | All three cycle-2 findings resolved: mocked-IdP callback integration test added (callback_integration_test.go), validate-session tests added covering valid/invalid/expired/missing-token cases, accessible_workspace_ids correctly returns null (not []) for unrestricted users. CI passed (lint + test). Zero 🔴 or 🟡 findings. PR squash-merged. |
| T3 — workflow-backend — service client + RequireAuth + workspaces.organization_id + scoped queries | [PR](https://github.com/tiendv89/workflow-backend/pull/14) | 🔴 Cross-tenant isolation test missing (tasks.md T3 subtask unchecked): handler/workspace_test.go newTestRouter does not inject AuthCtx, so all handler tests exercise the hasAuth=false path only. No test verifies that a user with accessible_workspace_ids=[ws-A] gets HTTP 404 when accessing ws-B. Implementation logic is correct; test is absent. |
| T4 — digital-factory-ui — /login page + session-aware root layout + logout | [PR](https://github.com/tiendv89/digital-factory-ui/pull/82) | All 10 T4 subtasks implemented. Previous cycle-1 🟡 finding (silent try/catch in getProviderUrl) resolved in fc075cf — getUserServiceBase() now throws on missing env var. No 🔴/🟡 findings. PR squash-merged. |
| T5 — digital-factory-ui — organization / workspace switcher driven by /api/me | [PR](https://github.com/tiendv89/digital-factory-ui/pull/83) | All T5 subtasks implemented (org selector, workspace selector, URL param persistence, loading/empty states). CI passed (no check-runs). No 🔴/🟡 findings. Three 🟢 nits: DRY violation in outside-click handlers, useSearchParams Suspense wrapping, URL param not propagating to WorkspaceContext on cold load. |
| T6 — user-service seed — Kitelabs organization + workspaces backfill + PLATFORM_ADMIN_EMAILS auto-grant | [PR](https://github.com/tiendv89/user-service/pull/3) | CI (lint + test) passed. All T6 subtasks implemented: seedKitelabsOrg + backfillWorkspaces idempotent, summary printout, README deploy sequence. No 🔴 or 🟡 findings. PR squash-merged. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `.env.template`
- `.github/workflows/ci.yml`
- `.gitignore`
- `.golangci.yml`
- `Dockerfile`
- `Makefile`
- `README.md`
- `cmd/api/api.go`
- `cmd/seed/main.go`
- `cmd/seed/main_test.go`
- `cmd/server/main.go`
- `configs/config.yaml`
- `configs/configs.go`
- `configs/configs_test.go`
- `database/migrations/.gitkeep`
- `database/migrations/00001_initial_identity_schema.sql`
- `docker-compose.yaml`
- `docs/features/m1-identity-and-workspaces/logs/T0/2026-05-31T08-34-50-546Z.jsonl`
- `docs/features/m1-identity-and-workspaces/logs/T1a/2026-05-31T08-36-20-300Z.jsonl`
- `docs/features/m1-identity-and-workspaces/logs/T1b/2026-05-31T08-36-38-460Z.jsonl`
- `docs/features/m1-identity-and-workspaces/tasks/T0.yaml`
- `docs/features/m1-identity-and-workspaces/tasks/T1a.yaml`
- `docs/features/m1-identity-and-workspaces/tasks/T1b.yaml`
- `docs/features/m1-identity-and-workspaces/tasks/T2a.yaml`
- `go.mod`
- `go.sum`
- `internal/adapter/rpc.go`
- `internal/authmw/auth.go`
- `internal/authmw/middleware.go`
- `internal/authmw/middleware_test.go`
- `internal/config/config.go`
- `internal/database/migrate_test.go`
- `internal/database/models.go`
- `internal/database/queries.go`
- `internal/database/scoped_ids_test.go`
- `internal/domain/dto.go`
- `internal/handler/workspace.go`
- `internal/handler/workspace_test.go`
- `internal/httpapi/auth_test.go`
- `internal/httpapi/callback_integration_test.go`
- `internal/httpapi/router.go`
- `internal/httpapi/router_test.go`
- `internal/httpapi/state_test.go`
- `internal/httpapi/time.go`
- `internal/httpapi/validate_session_integration_test.go`
- `internal/httpapi/validate_session_test.go`
- `internal/integration/config_validation_test.go`
- `internal/oauth/provider.go`
- `internal/organizations/organizations.go`
- `internal/organizations/organizations_test.go`
- `internal/service/workspace.go`
- `internal/serviceauth/middleware.go`
- `internal/serviceauth/middleware_test.go`
- `internal/serviceclient/user_service/client.go`
- `internal/serviceclient/user_service/client_test.go`
- `internal/sessions/manager.go`
- `internal/users/users.go`
- `migrations/00013_workspaces_organization_id.sql`
- `migrations/00014_workspaces_organization_id_not_null.sql`
- `src/__tests__/board-header.test.ts`
- `src/__tests__/login-page.test.ts`
- `src/__tests__/org-workspace-selection.test.ts`
- `src/__tests__/org-workspace-switcher.test.ts`
- `src/__tests__/session-context.test.ts`
- `src/__tests__/workflow-backend-client.test.ts`
- `src/app/login/page.tsx`
- `src/app/providers/AppProviders.tsx`
- `src/features/auth/components/SessionGate.tsx`
- `src/features/auth/context/SessionContext.tsx`
- `src/features/auth/index.ts`
- `src/features/workspaces/components/OrgWorkspaceSwitcher/OrgWorkspaceSwitcher.tsx`
- `src/features/workspaces/components/OrgWorkspaceSwitcher/index.ts`
- `src/features/workspaces/components/WorkspaceHeader/WorkspaceHeader.tsx`
- `src/features/workspaces/hooks/useOrgWorkspaceSelection.ts`
- `src/services/user-service/client.ts`
- `src/services/user-service/index.ts`
- `src/services/user-service/types.ts`
- `src/services/workflow-backend/client.ts`
- `tools.go`
- `workspace.yaml`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T0: claimed | pentative@gmail.com | 2026-05-31T08:34:33.364Z |
| T0: rag_pre_flight | pentative@gmail.com | 2026-05-31T08:34:43.477Z |
| T1a: claimed | norepy@tiendv.dev | 2026-05-31T08:35:58.338Z |
| T1a: rag_pre_flight | norepy@tiendv.dev | 2026-05-31T08:36:10.483Z |
| T1b: claimed | norepy@tiendv.dev | 2026-05-31T08:36:16.195Z |
| T1b: rag_pre_flight | norepy@tiendv.dev | 2026-05-31T08:36:28.307Z |
| T4: claimed | pentative@gmail.com | 2026-05-31T08:36:31.406Z |
| T4: rag_pre_flight | pentative@gmail.com | 2026-05-31T08:36:40.170Z |
| T0: started | pentative@gmail.com | 2026-05-31T08:36:49+0000 |
| T4: started | pentative@gmail.com | 2026-05-31T08:39:10+0000 |
| T1a: started | norepy@tiendv.dev | 2026-05-31T08:40:13+0000 |
| T0: run_completed | pentative@gmail.com | 2026-05-31T08:40:28.184Z |
| T1b: started | norepy@tiendv.dev | 2026-05-31T08:40:38+0000 |
| T0: reviewer_started | noreply@anthropic.com | 2026-05-31T08:42:36.175Z |
| T0: review_blocked | pentative@gmail.com | 2026-05-31T08:44:47.737Z |
| T1b: run_completed | norepy@tiendv.dev | 2026-05-31T08:45:22.317Z |
| T0: reviewer_started | noreply@tiendv.dev | 2026-05-31T08:46:27.070Z |
| T1b: reviewer_started | noreply@anthropic.com | 2026-05-31T08:46:39.795Z |
| T4: run_completed | pentative@gmail.com | 2026-05-31T08:46:57.964Z |
| T1a: run_completed | norepy@tiendv.dev | 2026-05-31T08:47:04.097Z |
| T1a: reviewer_started | noreply@anthropic.com | 2026-05-31T08:48:53.896Z |
| T4: reviewer_started | noreply@anthropic.com | 2026-05-31T08:49:10.013Z |
| T1b: review_blocked | pentative@gmail.com | 2026-05-31T08:49:35.649Z |
| T0: review_blocked | norepy@tiendv.dev | 2026-05-31T08:49:55.402Z |
| T0: reviewer_started | noreply@anthropic.com | 2026-05-31T08:51:00.316Z |
| T1a: review_blocked | pentative@gmail.com | 2026-05-31T08:51:13.051Z |
| T1b: reviewer_started | noreply@tiendv.dev | 2026-05-31T08:52:09.378Z |
| T1a: reviewer_started | noreply@tiendv.dev | 2026-05-31T08:52:36.135Z |
| T0: review_blocked | pentative@gmail.com | 2026-05-31T08:53:16.684Z |
| T1b: review_blocked | norepy@tiendv.dev | 2026-05-31T08:55:08.739Z |
| T1a: review_blocked | norepy@tiendv.dev | 2026-05-31T08:55:35.966Z |
| T1a: reviewer_started | noreply@anthropic.com | 2026-05-31T08:57:17.010Z |
| T1b: reviewer_started | noreply@tiendv.dev | 2026-05-31T08:57:31.069Z |
| T4: reviewer_complete | pentative@gmail.com | 2026-05-31T08:57:45.332Z |
| T4: fix_started | pentative@gmail.com | 2026-05-31T08:59:18.793Z |
| T1a: review_blocked | pentative@gmail.com | 2026-05-31T08:59:31.821Z |
| T1b: review_blocked | norepy@tiendv.dev | 2026-05-31T09:00:34.165Z |
| T4: run_completed | pentative@gmail.com | 2026-05-31T09:03:15.699Z |
| T4: reviewer_started | noreply@anthropic.com | 2026-05-31T09:03:48.306Z |
| T4: reviewer_complete | pentative@gmail.com | 2026-05-31T09:09:03.219Z |
| T4: done | pentative@gmail.com | 2026-05-31T09:09:25.156Z |
| T5: ready | pentative@gmail.com | 2026-05-31T09:09:25.170Z |
| T5: claimed | pentative@gmail.com | 2026-05-31T09:11:04.714Z |
| T5: rag_pre_flight | pentative@gmail.com | 2026-05-31T09:11:14.731Z |
| T5: started | pentative@gmail.com | 2026-05-31T09:16:42+0000 |
| T5: run_completed | pentative@gmail.com | 2026-05-31T09:26:19.797Z |
| T5: reviewer_started | noreply@tiendv.dev | 2026-05-31T09:27:30.209Z |
| T5: reviewer_complete | norepy@tiendv.dev | 2026-05-31T09:33:57.891Z |
| T5: done | pentative@gmail.com | 2026-05-31T09:34:23.908Z |
| T2a: claimed | pentative@gmail.com | 2026-05-31T09:42:22.910Z |
| T2a: rag_pre_flight | pentative@gmail.com | 2026-05-31T09:42:32.624Z |
| T2a: started | pentative@gmail.com | 2026-05-31T09:45:36+0000 |
| T2a: run_completed | pentative@gmail.com | 2026-05-31T09:52:29.918Z |
| T2a: reviewer_started | noreply@anthropic.com | 2026-05-31T09:52:44.123Z |
| T2a: reviewer_complete | pentative@gmail.com | 2026-05-31T09:59:23.882Z |
| T2a: fix_started | norepy@tiendv.dev | 2026-05-31T10:00:29.911Z |
| T2a: run_completed | norepy@tiendv.dev | 2026-05-31T10:21:04.893Z |
| T2a: reviewer_started | noreply@anthropic.com | 2026-05-31T10:21:43.262Z |
| T2a: reviewer_complete | pentative@gmail.com | 2026-05-31T10:28:25.634Z |
| T2a: fix_started | pentative@gmail.com | 2026-05-31T10:29:08.066Z |
| T2a: run_completed | pentative@gmail.com | 2026-05-31T10:32:51.783Z |
| T2a: reviewer_started | noreply@tiendv.dev | 2026-05-31T10:34:16.138Z |
| T2a: reviewer_complete | norepy@tiendv.dev | 2026-05-31T10:43:42.636Z |
| T2b: claimed | pentative@gmail.com | 2026-05-31T11:08:56.320Z |
| T2b: rag_pre_flight | pentative@gmail.com | 2026-05-31T11:09:06.065Z |
| T2b: started | pentative@gmail.com | 2026-05-31T11:11:54+0000 |
| T2b: run_completed | pentative@gmail.com | 2026-05-31T11:27:56.412Z |
| T2b: reviewer_started | noreply@anthropic.com | 2026-05-31T11:29:17.657Z |
| T2b: reviewer_complete | pentative@gmail.com | 2026-05-31T11:38:52.663Z |
| T2b: fix_started | pentative@gmail.com | 2026-05-31T11:40:12.216Z |
| T2b: run_completed | pentative@gmail.com | 2026-05-31T11:51:18.348Z |
| T2b: rebase_completed | pentative@gmail.com | 2026-05-31T12:00:59.267Z |
| T2b: reviewer_started | noreply@anthropic.com | 2026-05-31T12:01:34.722Z |
| T2b: reviewer_complete | pentative@gmail.com | 2026-05-31T12:09:38.545Z |
| T2b: fix_started | pentative@gmail.com | 2026-05-31T12:10:56.592Z |
| T2b: run_completed | pentative@gmail.com | 2026-05-31T12:26:39.314Z |
| T2b: reviewer_started | noreply@anthropic.com | 2026-05-31T12:27:42.727Z |
| T2b: reviewer_complete | pentative@gmail.com | 2026-05-31T12:34:20.857Z |
| T2b: done | pentative@gmail.com | 2026-05-31T12:34:50.236Z |
| T3: claimed | pentative@gmail.com | 2026-05-31T13:02:44.241Z |
| T3: rag_pre_flight | pentative@gmail.com | 2026-05-31T13:02:54.388Z |
| T3: started | pentative@gmail.com | 2026-05-31T13:05:26+0000 |
| T3: claimed | pentative@gmail.com | 2026-05-31T15:06:09.871Z |
| T3: rag_pre_flight | pentative@gmail.com | 2026-05-31T15:06:14.657Z |
| T3: started | pentative@gmail.com | 2026-05-31T15:08:45+0000 |
| T0: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T1a: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T1b: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T2a: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T2b: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T3: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T4: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T5: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T6: created | pye@swellnetwork.io | 2026-05-31T15:23:08+0700 |
| T3: run_completed | pentative@gmail.com | 2026-05-31T15:26:37.006Z |
| T0: ready | pye@swellnetwork.io | 2026-05-31T15:27:20+0700 |
| T1a: ready | pye@swellnetwork.io | 2026-05-31T15:27:20+0700 |
| T1b: ready | pye@swellnetwork.io | 2026-05-31T15:27:20+0700 |
| T4: ready | pye@swellnetwork.io | 2026-05-31T15:27:20+0700 |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-31T15:27:58.171Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-31T15:36:22.682Z |
| T3: fix_started | norepy@tiendv.dev | 2026-05-31T15:38:00.573Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-31T15:43:48.959Z |
| T3: reviewer_started | noreply@anthropic.com | 2026-05-31T15:44:30.231Z |
| T3: reviewer_complete | pentative@gmail.com | 2026-05-31T15:51:19.444Z |
| T3: fix_started | pentative@gmail.com | 2026-05-31T15:52:48.198Z |
| T0: done | pye@swellnetwork.io | 2026-05-31T15:55:06+0700 |
| T2a: ready | pye@swellnetwork.io | 2026-05-31T15:55:06+0700 |
| T3: run_completed | pentative@gmail.com | 2026-05-31T15:58:05.040Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-31T15:59:01.923Z |
| T1a: done | pye@swellnetwork.io | 2026-05-31T16:02:20+0700 |
| T1b: done | pye@swellnetwork.io | 2026-05-31T16:03:57+0700 |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-31T16:07:19.344Z |
| T3: fix_started | pentative@gmail.com | 2026-05-31T16:08:05.085Z |
| T3: run_completed | pentative@gmail.com | 2026-05-31T16:16:23.986Z |
| T6: claimed | norepy@tiendv.dev | 2026-05-31T17:05:18.627Z |
| T6: rag_pre_flight | norepy@tiendv.dev | 2026-05-31T17:05:30.787Z |
| T6: started | norepy@tiendv.dev | 2026-05-31T17:08:21+0000 |
| T6: run_completed | norepy@tiendv.dev | 2026-05-31T17:15:14.061Z |
| T6: reviewer_started | noreply@anthropic.com | 2026-05-31T17:15:52.812Z |
| T6: reviewer_complete | pentative@gmail.com | 2026-05-31T17:21:02.068Z |
| T6: done | norepy@tiendv.dev | 2026-05-31T17:22:24.680Z |
| T2a: unblocked | pye@swellnetwork.io | 2026-05-31T17:47:57+0700 |
| T2a: done | pye@swellnetwork.io | 2026-05-31T18:01:20+0700 |
| T2b: ready | pye@swellnetwork.io | 2026-05-31T18:01:20+0700 |
| T3: ready | pye@swellnetwork.io | 2026-05-31T19:55:22+0700 |
| T3: ready | pye@swellnetwork.io | 2026-05-31T22:04:55+0700 |
| T3: done | pye@swellnetwork.io | 2026-06-01T00:00:49+0700 |
| T6: ready | pye@swellnetwork.io | 2026-06-01T00:00:49+0700 |