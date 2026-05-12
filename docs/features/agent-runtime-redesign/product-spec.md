# Product Specification

## Feature
- Feature ID: `agent-runtime-redesign`
- Title: Agent Runtime Redesign

## Problem

The current handoff flow has a critical bug: the Handoff Trigger opens the feature branch PR targeting `main` (`feature/{id}` → `main`) and records it as `handoff_pr_url`. The Feature Done Watcher then checks whether that PR is merged. But when the PR is merged, GitHub deletes the feature branch — and the Watcher then tries to check out `origin/feature/{id}` to write `feature_status: done`, which fails because the branch no longer exists.

Additionally, there is no automation that merges the workspace feature PR — a human must do it manually, and the `done` state is never reliably written to `main`.

A secondary issue: `impl_feature_prs` is never populated by the Handoff Trigger, so the Feature Done Watcher always falls back to checking only `handoff_pr_url` and emits `impl_feature_prs_missing` every cycle.

## Goals

- Produce a detailed technical reference document that explains the current state of the runtime code: the orchestrator main loop (what it does each poll cycle), the executor lifecycle, and for every named process (Handoff Trigger, Feature Done Watcher, claim dispatch, reviewer dispatch, drift daemon, etc.) — what GitHub/git/YAML state it reads and writes, and whether each behavior is implemented as orchestrator code or delegated to a Claude skill. This document is the basis for all design decisions in this feature.

- Handoff PR targets the **feature branch**, not `main`, so the handoff commit lands on the feature branch while it is still alive.
- `impl_feature_prs` is populated by the Handoff Trigger with the implementation repo feature branch PR (e.g. `feature/{id}` → `main` in the impl repo).
- The Feature Done Watcher watches both `impl_feature_prs` and `handoff_pr_url`. When all are merged, it **auto-merges** the workspace feature PR (`feature/{id}` → `main` in the management repo).
- Before the workspace feature PR is merged, `feature_status: done` and `current_stage: done` are written to `status.yaml` on the feature branch (while it still exists). The merge into `main` then carries the done state naturally.
- The human's only manual steps are: review and merge the handoff PR (into the feature branch) and review and merge the impl repo feature branch PR(s). Everything after that is automated.

## Non-goals

- Changing how individual task PRs are handled (task branch → feature branch flow is unchanged).
- Auto-merging the impl repo feature branch PR without human review.
- Changing the handoff document format or content.

## Proposed Flow

```
[All tasks done]
      ↓
Handoff Trigger:
  - Generates handoff.md
  - Opens handoff PR:  handoff/feature-{id} → feature/{id}   (management repo)
  - Opens impl PR:     feature/{id} → main                    (impl repo)
  - Records both in status.yaml: handoff_pr_url + impl_feature_prs

[Human reviews]
      ↓
  - Merges handoff PR      → feature/{id} in management repo gets handoff commit
  - Merges impl PR(s)      → impl repo main gets feature code

[Feature Done Watcher — next poll]
      ↓
  - Detects all PRs merged
  - Writes feature_status: done + current_stage: done to status.yaml on feature/{id}
  - Auto-merges workspace feature PR: feature/{id} → main  (management repo)
  - Emits feature_done
```

## Success Criteria

- `feature_done_check_failed` is no longer emitted due to a deleted feature branch.
- `impl_feature_prs_missing` is no longer emitted for new features.
- After a human merges the handoff PR and impl PR, the workspace feature PR is merged automatically within one orchestrator poll cycle.
- `feature_status: done` and `current_stage: done` are written to `status.yaml` on the feature branch before the merge, and appear on `main` after the auto-merge completes.
