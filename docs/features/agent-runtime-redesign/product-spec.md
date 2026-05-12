# Product Specification

## Feature
- Feature ID: `agent-runtime-redesign`
- Title: Agent Runtime Redesign

## Problem

The orchestrator runtime has four interconnected bugs that together prevent features from completing reliably and make the executor model fragile as the system scales.

**Bug 1 — Feature branch deleted before done state can be written.**
The Handoff Trigger opens a PR from `feature/{id}` → `main` and records it as `handoff_pr_url`. When a human merges this PR, GitHub auto-deletes `feature/{id}`. The Feature Done Watcher's next poll attempts `git checkout -B feature/{id} origin/feature/{id}` — this fails because the remote ref no longer exists. The watcher emits `feature_done_check_failed` and the feature is stuck in `in_handoff` forever.

**Bug 2 — `impl_feature_prs` is never populated.**
The Handoff Trigger only promotes the management repo PR; it never opens implementation repo PRs or records them in `impl_feature_prs`. The Feature Done Watcher emits `impl_feature_prs_missing` every cycle and falls back to checking only `handoff_pr_url`, which is insufficient for multi-repo features.

**Bug 3 — No automation merges the workspace feature PR.**
After `feature_done` is emitted, the workspace feature PR (`feature/{id}` → `main`) sits open indefinitely. A human must merge it manually — but by then the feature branch has already been deleted (Bug 1), making the merge impossible. The `done` state is therefore never reliably written to `main`.

**Bug 4 — Executor filesystem isolation is broken.**
In `local-subprocess`, `syncRepo()` resets the management repo working tree on every poll cycle with no guard, creating a race with executor commits. In `local-docker`, `TASK_REPO_PATH` is set to a host filesystem path that does not exist inside containers; `materializeRepo()` always falls through to a full clone at an incorrect location. Two concurrent executors targeting the same impl repo share a single directory. The ABI is also missing `HANDLE` (for subprocess executors), `EXECUTOR_WORKDIR` (topology-agnostic working directory), and `MGMT_REPO_URL` (so executors can self-manage their management repo context).

## Goals

### 1. Fix the handoff flow (Bugs 1–3)

- The Handoff Trigger opens a PR from a new `handoff/feature-{id}` branch **into** `feature/{id}` (not into `main`). `feature/{id}` remains alive after this PR is merged.
- The Handoff Trigger opens implementation repo PRs (`feature/{id}` → `baseBranch` in each impl repo) and records them in `impl_feature_prs`.
- The Feature Done Watcher watches both `handoff_pr_url` and `impl_feature_prs`. When all are merged, it writes `feature_status: done` + `current_stage: done` to `status.yaml` on `feature/{id}` (while it still exists), then auto-merges the workspace feature PR (`feature/{id}` → `main`).
- The Lifecycle Manager records the workspace feature PR URL in a new field `workspace_feature_pr_url` (separate from `handoff_pr_url`).
- The human's only manual steps are: merge the handoff PR and merge the impl repo PR(s). All subsequent automation is orchestrator-driven.

### 2. Fix executor filesystem isolation (Bug 4)

- Each executor invocation receives a unique per-handle working directory (`EXECUTOR_WORKDIR = ${workspacesDir}/exec-{handle}`). Two concurrent executors targeting the same impl repo operate in fully isolated directories with no shared state.
- The ABI is updated: add `HANDLE`, `EXECUTOR_WORKDIR`, `MGMT_REPO_URL`; remove `TASK_REPO_PATH` and `WORKSPACE_ROOT` (executors derive both from `EXECUTOR_WORKDIR`).
- Executors use a two-phase startup: Phase 1 clones/pulls the management repo at `EXECUTOR_WORKDIR/mgmt` on `main` (read-only, for CLAUDE.md and skills); Phase 2 clones/reuses the impl repo at `EXECUTOR_WORKDIR/impl`.
- The orchestrator no longer maintains local impl repo clones. Operator `*_LOCAL_PATH` env vars (`WORKFLOW_LOCAL_PATH`, `DIGITAL_FACTORY_UI_LOCAL_PATH`, etc.) are no longer required for executor dispatch. The `skipImplRepoPull` guard is removed.
- The `handleMergeConflicts` inline step is replaced by a `kind: "rebase"` executor dispatch, removing the last remaining orchestrator dependency on a local impl repo path.

### 3. Runtime reference document

- Produce `docs/features/agent-runtime-redesign/runtime-reference.md`: a standalone technical reference covering the full poll cycle, executor ABI contracts, per-process read/write/skill-vs-code map, and all known gaps. This document is the baseline for all design decisions in this feature. *(Completed — produced alongside the technical design.)*

## Non-goals

- Changing how individual task PRs are handled (task branch → feature branch flow is unchanged).
- Auto-merging impl repo feature branch PRs without human review.
- Changing the handoff document format or content.
- Adding new executor runtimes (no K8s adapter, no new container topology).
- Fixing or removing the `kind: "review-fix"` dead code path (out of scope).
- Changing the reviewer or fix-agent dispatch flow.

## Proposed Flow

### Handoff flow (post-redesign)

```
[All tasks done]
      ↓
Handoff Trigger:
  - Generates handoff.md
  - Creates handoff/feature-{id} branch from feature/{id}
  - Opens handoff PR:  handoff/feature-{id} → feature/{id}   (management repo, non-draft)
  - Opens impl PR:     feature/{id} → baseBranch              (each impl repo)
  - Records: handoff_pr_url + impl_feature_prs in status.yaml
  - Sets feature_status: in_handoff

[Human reviews]
      ↓
  - Merges handoff PR  →  feature/{id} stays alive (PR targeted it, not main)
  - Merges impl PR(s)  →  impl repo gets feature code

[Feature Done Watcher — next poll]
      ↓
  - All PRs merged → checkout feature/{id} (still alive)
  - Write feature_status: done + current_stage: done to status.yaml on feature/{id}
  - Auto-merge workspace_feature_pr_url (feature/{id} → main)
  - Emit feature_done
```

### Executor isolation (post-redesign)

```
[Orchestrator dispatches executor]
      ↓
  adapter.submit({
    HANDLE:          exec-{uuid}
    EXECUTOR_WORKDIR: ${workspacesDir}/exec-{uuid}   (subprocess)
                    : /workspace                      (docker, per-handle volume)
    MGMT_REPO_URL:   git URL of management repo
    TASK_REPO_URL:   git URL of impl repo
    TASK_REPO_BRANCH, TASK_BASE_BRANCH, ...
  })
      ↓
[Executor startup — two phases]
  Phase 1: clone/pull MGMT_REPO_URL → EXECUTOR_WORKDIR/mgmt  (main, read-only)
           → WORKSPACE_ROOT = EXECUTOR_WORKDIR/mgmt
  Phase 2: clone/reuse TASK_REPO_URL → EXECUTOR_WORKDIR/impl (on task branch)
           → TASK_REPO_PATH = EXECUTOR_WORKDIR/impl
      ↓
[Executor does work in EXECUTOR_WORKDIR/impl]
      ↓
[Reap loop on ack()]
  → rm -rf EXECUTOR_WORKDIR  (cleanup)
```

## Success Criteria

- `feature_done_check_failed` is no longer emitted due to a deleted feature branch.
- `impl_feature_prs_missing` is no longer emitted for new features.
- After a human merges the handoff PR and impl PR(s), the workspace feature PR is merged automatically within one orchestrator poll cycle.
- `feature_status: done` and `current_stage: done` appear on `main` after the auto-merge completes.
- Two concurrent executors targeting the same impl repo produce no shared-state conflicts.
- Operator `*_LOCAL_PATH` env vars are no longer required for the orchestrator to dispatch executors.
- `local-docker` executors correctly materialise the impl repo inside the container (no more host-path `TASK_REPO_PATH` mismatch).
