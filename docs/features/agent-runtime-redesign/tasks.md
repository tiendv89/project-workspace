# Task Breakdown — Agent Runtime Redesign

**Feature status:** `in_tdd` | **Stage:** `tasks` (draft) | Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T2 | 1 | Lifecycle Manager: record workspace_feature_pr_url | — |
| T5 | 1 | ABI + executor startup: EXECUTOR_WORKDIR two-phase startup | — |
| T3 | 2 | Handoff Trigger redesign | T2 |
| T4 | 3 | Feature Done Watcher redesign | T2, T3 |
| T6 | 3 | Orchestrator dispatch + adapters | T5, T3 |

---

## T2 — Lifecycle Manager: record workspace_feature_pr_url

### Description

Update `runtime/orchestrator/src/feature-branch/lifecycle-manager.ts` so that when it opens the draft PR (`feature/{id}` → `baseBranch`), it records the URL as `workspace_feature_pr_url` in `status.yaml` instead of `handoff_pr_url`.

Also remove the step 5 re-promotion logic (the block that promotes the `handoff_pr_url` draft PR from draft to ready-for-review when `feature_status` is `in_handoff`). This logic is superseded by the Handoff Trigger's new non-draft PR flow in T3.

Backward-compatibility guard: if `handoff_pr_url` is already set but `workspace_feature_pr_url` is absent (pre-migration feature), treat `handoff_pr_url` as `workspace_feature_pr_url` in memory so existing features still resolve the workspace feature PR URL correctly.

Key acceptance criteria:
- New features: Lifecycle Manager writes `workspace_feature_pr_url` on first branch creation; `handoff_pr_url` is not touched by Lifecycle Manager.
- Existing features: if `handoff_pr_url` set and `workspace_feature_pr_url` absent, backward-compat read guard populates it in-memory (no schema migration needed).
- Step 5 re-promotion code removed; existing unit tests updated or removed accordingly.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read `lifecycle-manager.ts`; identify where `handoff_pr_url` is written (step 4) and where re-promotion logic lives (step 5)
- [ ] Rename the step-4 write from `handoff_pr_url` to `workspace_feature_pr_url`; update the read guard to skip if `workspace_feature_pr_url` already set
- [ ] Add backward-compat: if `handoff_pr_url` set but `workspace_feature_pr_url` absent, treat `handoff_pr_url` as `workspace_feature_pr_url` in-memory
- [ ] Delete step 5 re-promotion block
- [ ] Update any TypeScript types or status.yaml schema types to add `workspace_feature_pr_url`
- [ ] Run tests; update or remove tests that reference `handoff_pr_url` in the Lifecycle Manager context

---

## T5 — ABI + executor startup: EXECUTOR_WORKDIR two-phase startup

### Description

This task makes two related changes that together fix the executor filesystem isolation gap (Bug 4 from the technical design).

**ABI changes (`runtime/abi/src/types.ts` + `runtime/abi/docs/abi-spec.md`):**
- Add `handle` / `HANDLE` (executor invocation UUID; formalise existing docker usage; new for subprocess)
- Add `executorWorkdir` / `EXECUTOR_WORKDIR` (per-handle base directory; new)
- Add `mgmtRepoUrl` / `MGMT_REPO_URL` (management repo git URL; new)
- Remove `taskRepoPath` / `TASK_REPO_PATH` (executor derives as `${EXECUTOR_WORKDIR}/impl`)
- Remove `WORKSPACE_ROOT` from formal ABI (executor derives as `${EXECUTOR_WORKDIR}/mgmt`)
- Add `"rebase"` to `HandleKind`

**Executor startup (`runtime/executors/claude/src/index.ts`):**
- Replace the single `materializeRepo(taskRepoUrl, taskRepoBranch, taskRepoPath, sshKeyPath)` call with two-phase startup:
  - Phase 1: management repo — clone/pull `MGMT_REPO_URL` at `${EXECUTOR_WORKDIR}/mgmt` on `main` (read-only); set `WORKSPACE_ROOT = ${EXECUTOR_WORKDIR}/mgmt`
  - Phase 2: impl repo — existing `materializeRepo` logic, corrected path to `${EXECUTOR_WORKDIR}/impl`; set `TASK_REPO_PATH = ${EXECUTOR_WORKDIR}/impl`
- Order: Phase 1 → Phase 2 → `copyWorkspaceClaude()` → `setupGlobalSkills()` → spawn Claude with `cwd: impl_dir`
- Phase 1 is idempotent: if `${EXECUTOR_WORKDIR}/mgmt` is already a valid git repo with the correct origin URL, run `git fetch origin && git checkout main && git pull --ff-only origin main` instead of a fresh clone.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Add `handle`, `executorWorkdir`, `mgmtRepoUrl` to `ExecutorPortInput` in `types.ts`; remove `taskRepoPath`
- [ ] Remove `WORKSPACE_ROOT` from the formal ABI input table in `types.ts`
- [ ] Add `"rebase"` to `HandleKind`
- [ ] Update `abi-spec.md` to reflect all ABI field changes
- [ ] Read `runtime/executors/claude/src/index.ts`; identify `materializeRepo` call site and where `WORKSPACE_ROOT` / `TASK_REPO_PATH` are consumed
- [ ] Implement Phase 1 management repo startup (clone/pull on main; idempotent)
- [ ] Update Phase 2 to derive `impl_dir = ${EXECUTOR_WORKDIR}/impl` rather than reading it from `TASK_REPO_PATH` env
- [ ] Set `WORKSPACE_ROOT` and `TASK_REPO_PATH` as process env vars from the derived paths (so `copyWorkspaceClaude` and `setupGlobalSkills` continue to work unchanged)
- [ ] Run tests

---

## T3 — Handoff Trigger redesign

### Description

Rewrite `runtime/orchestrator/src/handoff/handoff-trigger.ts` to implement the new PR flow described in §4.3 of the technical design.

**Remove:** `promoteOrCreateFeaturePr` call (which promoted the `feature/{id}` → `main` draft PR from draft to ready-for-review).

**Add:** four new steps executed after `handoff.md` is generated:

**Step 5a** — create `handoff/feature-{id}` branch from `feature/{id}`:
```
git fetch origin
git checkout -B handoff/feature-{id} origin/feature/{id}
```

**Step 5b** — commit `handoff.md` to `handoff/feature-{id}`:
```
git add handoffs/handoff.md
git commit -m "chore({featureId}): handoff document"
git push origin handoff/feature-{id}
```

**Step 5c** — open management-repo handoff PR (non-draft, ready for review immediately):
- head: `handoff/feature-{id}`, base: `feature/{id}`
- Title: `feat({featureId}): handoff — {title}`
- Record URL as `status.yaml.handoff_pr_url`

**Step 5d** — open impl repo PRs (one per unique impl repo referenced by task YAMLs, skip management-repo):
- For each unique `task.repo` value that is not `management-repo`:
  - Check whether `feature/{id}` exists on that impl repo's origin (emit `impl_repo_feature_branch_missing` and skip if absent — non-fatal)
  - Open PR: `feature/{id}` → `baseBranch` (from `workspace.yaml` for that repo)
  - Record as entry in `status.yaml.impl_feature_prs`: `{repo: repoId, url: prUrl, status: "open"}`

**status.yaml writes (step 6):**
- `handoff_pr_url` = management-repo handoff PR URL (new semantics)
- `impl_feature_prs` = list of impl repo PR entries
- `feature_status: in_handoff`
- `current_stage: handoff`
- Does NOT touch `workspace_feature_pr_url` (set by Lifecycle Manager in T2)

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read `handoff-trigger.ts` fully; identify `promoteOrCreateFeaturePr` call site and all status.yaml write sites
- [ ] Remove `promoteOrCreateFeaturePr` and all draft-promotion logic in this file
- [ ] Implement Step 5a: create `handoff/feature-{id}` branch from `feature/{id}` (idempotent: reset if already exists)
- [ ] Implement Step 5b: commit `handoff.md` to `handoff/feature-{id}` and push
- [ ] Implement Step 5c: open non-draft management-repo handoff PR via GitHub REST API; record URL as `handoff_pr_url` in `status.yaml`
- [ ] Implement Step 5d: read task YAMLs to collect unique impl repo IDs (excluding management-repo); check feature branch existence before opening; open impl repo PR via GitHub REST API; record in `impl_feature_prs`
- [ ] Write updated `status.yaml` (handoff_pr_url, impl_feature_prs, feature_status, current_stage)
- [ ] Run tests; update tests that checked `promoteOrCreateFeaturePr` behaviour

---

## T4 — Feature Done Watcher redesign

### Description

Rewrite `runtime/orchestrator/src/poll/handle-feature-done.ts` to implement the corrected done-state write sequence and workspace feature PR auto-merge described in §4.5 of the technical design.

**PR check (corrected targets — same logic, new semantics):**
- `handoff_pr_url` now points to `handoff/feature-{id}` → `feature/{id}` (after T3 is deployed). Merging this PR does not delete `feature/{id}`, so the checkout in the next step will succeed.
- `impl_feature_prs` is now populated (after T3). No more `impl_feature_prs_missing`.

**New write sequence when all PRs are merged:**

1. Checkout `feature/{id}` (still alive):
   ```
   git fetch origin
   git checkout -B feature/{id} origin/feature/{id}
   ```

2. Write done state to `status.yaml` on the feature branch and push:
   ```yaml
   feature_status: done
   current_stage: done
   ```

3. Auto-merge the workspace feature PR:
   - Read `workspace_feature_pr_url` from `status.yaml`
   - If absent: emit `workspace_feature_pr_url_missing` and skip (backward compat)
   - Check mergeability via GitHub REST API; if `CONFLICTING`: emit `workspace_feature_pr_not_mergeable` and skip
   - If mergeable: call `PUT /pulls/{n}/merge` (squash); emit `workspace_feature_pr_merged` or `workspace_feature_pr_merge_failed`

4. Emit `feature_done`.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read `handle-feature-done.ts` fully; identify the checkout + write block and where `handoff_pr_url` / `impl_feature_prs` are read
- [ ] Verify the PR-check logic handles `impl_feature_prs` absent (emit warning, fall back to checking only `handoff_pr_url`)
- [ ] Rewrite done-state write sequence: checkout `feature/{id}`; write `feature_status: done` + `current_stage: done`; commit + push to `feature/{id}`
- [ ] Add auto-merge step: read `workspace_feature_pr_url`; check mergeability; call `PUT /pulls/{n}/merge`; emit appropriate events
- [ ] Add backward-compat guard: if `workspace_feature_pr_url` absent, skip auto-merge and emit `workspace_feature_pr_url_missing`
- [ ] Emit `feature_done` after merge (or after skip)
- [ ] Run tests; add tests for: done state written to feature branch; auto-merge success; auto-merge skipped when url absent; `CONFLICTING` merge skipped

---

## T6 — Orchestrator dispatch + adapters

### Description

This is the largest task in the feature, touching the orchestrator core dispatch path, both executor adapters, the bootstrap, and the reap loop. All changes are confined to the `workflow` repo. This task depends on T5 (ABI types must be defined) and T3 (reap loop `merge-done` path calls `fireHandoffTrigger` which T3 rewrites).

**`runtime/orchestrator/src/bootstrap/bootstrap.ts`:**
- Remove `syncRepo()` calls for impl repos from `pullWorkspaces`; only management repo and workflow repo remain.
- Remove the `skipImplRepoPull` / `execInFlight` guard.

**`runtime/orchestrator/src/main.ts` + `config/workspace-config.ts`:**
- Remove `resolveRepoLocalPath()` from the executor dispatch path. Operator env vars `WORKFLOW_LOCAL_PATH`, `DIGITAL_FACTORY_UI_LOCAL_PATH`, etc. no longer referenced.
- `buildAndSubmitExecutor`: pass `executorWorkdir = ${workspacesDir}/exec-{handle}`, `handle`, and `mgmtRepoUrl`; remove `taskRepoPath` and `WORKSPACE_ROOT`.
- `mgmtRepoUrl` resolved from `workspace.yaml` management-repo `github:` field.
- Step 5a: when `checkInReviewPrs` reports `mergeable: false`, dispatch `kind: "rebase"` via `adapter.submit()` (replaces synchronous `handleMergeConflicts`).
- Step 5a: when `checkInReviewPrs` reports `merged: true`, defer to async `handleMergedPrs` (orchestrator code, not a broker executor).
- Remove `handleWorkspacePrRecoveries` call entirely.

**`runtime/orchestrator/src/adapters/executor/subprocess.ts`:**
- Add `HANDLE`, `EXECUTOR_WORKDIR = ${workspacesDir}/exec-{handle}`, `MGMT_REPO_URL` to subprocess env.
- Remove `TASK_REPO_PATH` and `WORKSPACE_ROOT`.
- `ack()`: add `rm -rf ${workspacesDir}/exec-{handle}` after result is processed.

**`runtime/orchestrator/src/adapters/executor/docker-run.ts`:**
- Change volume mount: `-v ${workspacesDir}/exec-{handle}:/workspace` (per-handle, isolated; was flat `-v ${workspacesDir}:/workspace`).
- Pass `EXECUTOR_WORKDIR=/workspace`, `MGMT_REPO_URL`.
- Remove `TASK_REPO_PATH` and `WORKSPACE_ROOT`.
- `ack()`: add `rm -rf ${workspacesDir}/exec-{handle}` host-path cleanup after `docker rm`.

**`runtime/orchestrator/src/poll/reap-loop.ts`:**
- Add handler for `kind === "rebase"`:
  - `terminal_status === "in_review"`: write `conflict_state: resolved` to task YAML on mgmt repo
  - `terminal_status === "blocked"`: write `status: blocked, blocked_reason: pr_conflict` to task YAML on mgmt repo
- Leave `kind === "review-fix"` handler in place (dead code — do not remove).

**`runtime/orchestrator/src/pr-response/auto-rebase.ts`:**
- Remove `handleMergeConflicts` from the inline PR poll path. The core rebase logic moves into the `kind: "rebase"` executor subprocess.
- `autoRebase` may be repurposed as the executor briefing template or removed if the executor implements the logic directly.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read all affected files: `bootstrap.ts`, `main.ts`, `workspace-config.ts`, `subprocess.ts`, `docker-run.ts`, `reap-loop.ts`, `auto-rebase.ts`
- [ ] Remove impl repo `syncRepo()` calls and `skipImplRepoPull` guard from `bootstrap.ts`
- [ ] Update `buildAndSubmitExecutor` in `main.ts`: pass `executorWorkdir`, `handle`, `mgmtRepoUrl`; remove `taskRepoPath`, `WORKSPACE_ROOT`
- [ ] Replace inline `handleMergeConflicts` with `kind: "rebase"` `adapter.submit()` in PR poll step
- [ ] Defer `handleMergedPrs` as async (not awaited inline)
- [ ] Remove `handleWorkspacePrRecoveries` call
- [ ] Update `subprocess.ts`: add `HANDLE`, `EXECUTOR_WORKDIR`, `MGMT_REPO_URL`; remove `TASK_REPO_PATH`, `WORKSPACE_ROOT`; add `ack()` cleanup
- [ ] Update `docker-run.ts`: per-handle volume mount; add `EXECUTOR_WORKDIR=/workspace`, `MGMT_REPO_URL`; remove `TASK_REPO_PATH`, `WORKSPACE_ROOT`; add `ack()` cleanup
- [ ] Add `kind === "rebase"` handler to `reap-loop.ts`
- [ ] Remove `handleMergeConflicts` inline call from `auto-rebase.ts` / `main.ts` poll step
- [ ] Remove `resolveRepoLocalPath` from dispatch config paths
- [ ] Run tests; TypeScript compilation must pass (requires T5 ABI types already merged or co-located)
