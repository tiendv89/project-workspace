# Tasks — Check Status Across All Branches

**Feature status:** [`status.yaml`](status.yaml) — technical design approved, task planning stage.
**Machine state:** [`tasks/T<n>.yaml`](tasks/) — source of truth for status, dependencies, branch, PR, and log.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | Branch sync service | — |
| T2 | 2 | Sync API and poller | T1 |
| T3 | 3 | Refresh integration and smoke coverage | T2 |
| T4 | 3 | Documentation and operational notes | T1 |

---

## T1 — Branch sync service

### Description

Implements the core branch-aware sync service in `digital-factory-ui`. This task adds a git-command wrapper, branch resolution, remote task YAML reading through `git show`, freshness comparison, runtime-field copying, local task YAML writing, lock handling, and one-commit sync write-back to the management repo base branch.

This is the root implementation task because every other task depends on the service contract and result shape.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `src/lib/git-command.ts` with argument-array git execution and shared SSH environment support.
- [ ] Refactor existing `src/lib/git.ts` SSH key resolution so sync and commit helpers use one implementation.
- [ ] Add `src/lib/task-status-sync.ts` with branch resolution from `task.branch` and `workspace.yaml -> git.branch_pattern`.
- [ ] Fetch task branches with `git fetch origin +refs/heads/feature/*:refs/remotes/origin/feature/* --prune`.
- [ ] Read remote task YAML using `git show origin/<branch>:docs/features/<feature_id>/tasks/T<n>.yaml` without checkout.
- [ ] Compare remote and local task-file freshness using git commit timestamps, with YAML timestamp fallback.
- [ ] Copy only runtime fields: `status`, `blocked_reason`, `blocked_context`, `execution`, `pr`, `workspace_pr`, `log`, and `branch`.
- [ ] Validate remote YAML task id before copying; skip mismatches with structured skip reasons.
- [ ] Add workspace-scoped lock handling under `.git/task-status-sync.lock` with stale-lock cleanup.
- [ ] Commit and push changed task YAML files in one sync commit when updates exist.
- [ ] Add unit tests for branch resolution, freshness comparison, runtime-field copy, skip reasons, and idempotent no-change sync.

---

## T2 — Sync API and poller

### Description

Exposes the branch sync service through a workspace-scoped Next.js API route and mounts a client poller that runs every 15 seconds while an active workspace is selected. The poller must avoid overlapping requests, skip hidden tabs, and refresh server-rendered data only when the sync result changed task files.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `src/app/api/workspaces/[workspaceId]/sync-task-status/route.ts` as a dynamic uncached POST route.
- [ ] Resolve workspace path with `getWorkspaceByIdFromScan(workspaceId)`.
- [ ] Resolve `management-repo.base_branch` from `workspace.yaml`.
- [ ] Return compact JSON with `ok`, `changed`, `updated`, `skipped`, and optional `error`.
- [ ] Add `src/components/task-sync/task-status-sync-poller.tsx`.
- [ ] Mount the poller under `WorkspaceProvider` in `src/app/layout.tsx`.
- [ ] Run immediately on workspace change, then every 15 seconds.
- [ ] Skip when no active workspace exists, when the tab is hidden, or when a sync request is already in flight.
- [ ] Call `router.refresh()` only when the API result reports `changed: true`.
- [ ] Add route/poller tests for success, no-change, in-flight skip, hidden-tab skip, and error handling.

---

## T3 — Refresh integration and smoke coverage

### Description

Verifies that the dashboard, feature detail, and task board surfaces update from branch-synced task YAML without introducing client-side task data fetching. This task tightens user-facing integration, result observability, and smoke coverage after the API and poller are in place.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices
- browser-qa-frontend

### Subtasks
- [ ] Confirm dashboard task counts update after the poller syncs changed task YAML.
- [ ] Confirm `/features/[featureId]` task table updates after `router.refresh()`.
- [ ] Confirm `/tasks` Kanban columns reflect synced statuses after `router.refresh()`.
- [ ] Add a lightweight user-visible failure surface only if sync fails repeatedly; do not show noisy success notifications.
- [ ] Add or update tests around server-rendered task readers so synced YAML remains the single dashboard data source.
- [ ] Run `pnpm lint`, `pnpm build`, and the repo's available test command.
- [ ] Perform a manual smoke test with a task branch containing a newer `status: in_review` YAML.
- [ ] Confirm repeated no-op polling creates no new commits.

---

## T4 — Documentation and operational notes

### Description

Documents how branch status sync works for local dashboard operators and future agents. This includes the 15-second polling behavior, git/SSH requirements, skip/failure cases, and the guarantee that the dashboard mirrors task branch YAML but does not execute tasks, merge branches, or infer task status from PRs.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Update `digital-factory-ui` README or local docs with the branch status sync overview.
- [ ] Document required git credentials: `SSH_PRIVATE_KEY` or `SSH_KEY_PATH`, plus git author identity.
- [ ] Document polling behavior: active workspace only, visible tab only, 15-second interval, no overlapping runs.
- [ ] Document skipped states: missing branch, missing branch task YAML, invalid YAML, id mismatch, dirty task file, and push rejection.
- [ ] Document that sync commits mirror task branch YAML to the management repo base branch.
- [ ] Document non-goals: no task execution, no branch merge, no PR-derived status.
- [ ] Include a manual verification recipe using `feature/feature-status-dashboard-v2-T1` as the branch naming example.
