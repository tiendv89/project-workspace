# Product Specification

## Feature
- Feature ID: `go-orchestrator-parity`
- Title: Go Orchestrator — Autonomous Parity (Reviewer Cycle, Drift Daemon, Handoff Trigger)

## Problem
The `workflow-db` feature ships the Go/Postgres orchestrator as a **human-merge slice**: it can claim tasks atomically in the DB, dispatch to executors, reap completions to `in_review`, and reach `done` only when a **human merges the impl PR**. That proves the DB write path, owner-partitioned coexistence with the TS orchestrator, and scoped YAML→DB sync — but it is **not autonomous**. A human must review and merge every PR, and features never advance past task-level `done`.

To let the Go orchestrator actually *replace* the TS orchestrator, it must run the same autonomous loops the TS path runs beyond basic task lifecycle:
- the **reviewer cycle** (dispatch a reviewer agent, route its verdict, run the REQUEST_CHANGES fix loop, handle incomplete reviews),
- the **drift daemon** (detect base-branch advance and rebase the feature branch),
- the **handoff trigger** (feature-level `done` and feature-branch PRs).

Without these, the Go orchestrator cannot drive a feature end-to-end without a human in the loop, and parity with the TS orchestrator is incomplete.

## Background / dependency
This feature **depends on `workflow-db`** and builds directly on top of it. `workflow-db` establishes, in the DB, the primitives this feature reuses:
- the guarded-`UPDATE` claim primitive (every transition here is the same shape),
- the owner-partitioned broker (`owner='go'` completion queue),
- the PR-merge poll (`in_review → done`),
- dependency auto-ready.

This feature adds the **reviewer and feature-completion automation** on top — it does not redo the write path. See `docs/features/workflow-db/technical-design.md` §3-E and §8 ("Deferred scope") for the exact seam.

## Goals
- **Reviewer cycle in the Go orchestrator.** Implement the full task-FSM reviewer sub-machine against the DB using the existing guarded-`UPDATE` primitive:
  - `in_review → reviewing` (reviewer-dispatch claim — first-write-wins, mirrors the TS `reviewing` duplicate-dispatch guard)
  - `reviewing → review_passed` (APPROVE verdict; holding state until the impl PR merges)
  - `reviewing → change_requested` (REQUEST_CHANGES verdict) and `change_requested → in_progress` (fix-agent claim)
  - `reviewing → review_incomplete` and `review_incomplete → reviewing` (retry up to `MAX_REVIEW_INCOMPLETES`), `review_incomplete → blocked` (escalation after max attempts)
  - `review_passed → done` via the PR-merge poll already built in `workflow-db`
  - honour `execution.requires_human_review: true` (reviewer posts APPROVE but skips merge; orchestrator waits for the human merge)
- **Drift daemon.** Detect when the base branch advances past `feature_branch_base_sha`, set `drift_detected`/`drift_reason` on `status.yaml`'s feature-branch fields, and rebase the feature branch; reset `drift_detected` once rebased.
- **Handoff trigger.** When all of a go feature's tasks are `done`, open the management-repo feature-branch PR and the implementation-repo feature-branch PR(s), and populate `handoff_pr_url` / `impl_feature_prs` on `status.yaml`.
- **End-to-end autonomous run.** Drive a go feature from `ready` to feature-level `done` with **no human merge** — reviewer APPROVE → impl PR merge → feature done — in parallel with a legacy TS feature, preserving the single-owner-per-feature invariant.

## Non-goals
- Re-implementing the `workflow-db` write path, atomic claim, broker partitioning, or PR-merge poll — those are delivered by `workflow-db` and reused here.
- HTTP write API / MCP server for external (non-runtime) write clients — that remains a separate downstream feature.
- Migrating existing git/YAML features into the DB — net-new-in-Go only (unchanged from `workflow-db`).
- Per-org tenant-isolation hardening beyond the existing `workspaces.organization_id` scoping (forward work; the orchestrator still populates `organization_id`).
- Retiring the TS orchestrator — this feature brings the Go orchestrator to parity so retirement becomes possible later, but the cutover itself is out of scope.

## Open questions
1. **Reviewer agent transport.** Does the Go orchestrator dispatch the reviewer via the same `platform:dispatch` stream + executor (running `review-pr`) as task work, or a distinct path? (Likely the same dispatch surface — confirm in technical design.)
2. **Verdict ingestion.** How does the reviewer's `result.json` / GitHub review state get read back — broker completion (as for impl work) or a GitHub review poll? Resolve in technical design.
3. **Drift daemon cadence & locking.** Polling interval and how rebase races with an in-flight executor on the same feature branch are avoided.
4. **Handoff PR creation.** Reuse `pr-create` semantics from Go (REST via `GITHUB_TOKEN`), and confirm `impl_feature_prs` shape matches the orchestrator-written contract in `CLAUDE.md` (status.yaml feature-branch fields).
5. **Parity scope cutoff.** Confirm whether `review_incomplete` retry/escalation ships in this feature's v1 or is itself split further.

## Success criteria
- A go feature is driven to feature-level `done` autonomously (reviewer APPROVE, no human merge) in a coexistence test alongside a legacy TS feature; the TS orchestrator never drains a go completion and the YAML→DB sync never deletes go rows.
- A REQUEST_CHANGES verdict routes the task back through `change_requested → in_progress` and a second review reaches APPROVE.
- A base-branch advance is detected by the drift daemon and the feature branch is rebased without manual intervention.
