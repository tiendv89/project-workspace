
# Product Specification

## Feature
- Feature ID: `go-orchestrator-handoff-ui`
- Title: Display Go Orchestrator Handoff PR Info

## Problem
For **ts-flow** features, the feature UI (`digital-factory-ui`, e.g. `FeatureIDEDocsPanel` / `feature-document-panel.tsx`) can show handoff status because a `handoffs/handoff.md` file is committed to the management repo feature branch — the UI reads that file and displays its content alongside PR state (via helpers like `resolvePRState` in `workflow-backend`'s `internal/handler/document.go`).

For **go-flow** features, there is no `handoffs/handoff.md` file — the Go orchestrator (`workflow-orchestrator` repo) instead tracks handoffs directly in Postgres. It already has the domain model for this:
- `internal/database/queries/handoffs.sql.go` — `InsertHandoff`, `GetHandoffFeatureInfo`
- `internal/database/queries/handoff_prs.sql.go` — per-PR rows including `SetHandoffPRConflicted`, implying each handoff can have one or more associated PRs with individual state
- `internal/orchestrator/feature_lifecycle.go` — `CheckAndFinalizeHandoffs`, `maybeFinalize`, and a `ListHandoffPRsByHandoff` query used to decide whether a handoff is fully merged

Today none of this handoff/handoff-PR data is exposed to the workspace UI for go features. A user looking at a go-owned feature (e.g. via `workflow-backend`'s document/feature endpoints, surfaced in `digital-factory-ui`) has no way to see:
- whether a handoff exists for the feature,
- what PR(s) belong to that handoff (there can be more than one — one per repo touched, similar to the `impl_feature_prs` concept used on the ts side),
- the current status of each of those PRs (open / merged / conflicted / etc).

## Goals
- For any feature owned by the `go` orchestrator, if a handoff exists (a row in the `handoffs` table via `GetHandoffFeatureInfo`), expose it through the `workflow-backend` API so the UI can render it.
- Expose **all** handoff PRs associated with that handoff (via `ListHandoffPRsByHandoff` / the `handoff_prs` table) — not just a single URL — since a go feature's handoff may span multiple repos/PRs.
- For each handoff PR, surface its current status (e.g. open, merged, conflicted) — reusing/aligning with the existing PR-state resolution logic in `internal/handler/document.go` (`resolvePRState`) where applicable, or the `handoff_prs` table's own status column if it already tracks this (e.g. `SetHandoffPRConflicted` suggests a `conflicted` state exists there).
- Display this information in `digital-factory-ui` on the feature detail view, in a manner comparable to how ts-flow features surface their `handoffs/handoff.md` content today (e.g. alongside `FeatureIDEDocsPanel` / `feature-document-panel.tsx`), but sourced from the Go orchestrator's DB-backed handoff/handoff-PR data instead of a git file.
- If no handoff exists yet for the feature, the UI should clearly indicate "no handoff" rather than showing an error or blank section.

- The `digital-factory-ui` frontend must call the new endpoint through the existing `workflow-bff` proxy — not directly against `workflow-backend`. `workflow-bff` already has a generic pass-through (`ProxyHandler.Proxy` + `RoutingTable.Resolve` in `internal/app/api/handler/proxy/`) that forwards requests to `workflow-backend` by route pattern, matching how other `workflow-backend` endpoints (e.g. task-create, feature-name-filter, unblock — see `routing_test.go`) are already reached from the FE. The new handoff endpoint's route must be added to `workflow-bff`'s routing table so it resolves to `workflow-backend`, and the FE must call the corresponding `workflow-bff` URL (not the raw `workflow-backend` URL).

## Non-goals
- Do not change how ts-flow features track or display handoffs (the `handoffs/handoff.md` file-based mechanism is untouched).
- Do not change the Go orchestrator's handoff creation, finalization, or PR-conflict-resolution logic (`CheckAndFinalizeHandoffs`, `maybeFinalize`, `SetHandoffPRConflicted`, etc.) — this feature is read/display only.
- Do not add the ability to approve/merge/act on handoff PRs from this UI — this is a display-only surface; actions on PRs continue to happen on GitHub (or existing approval flows) as today.
- Do not build a generic multi-orchestrator abstraction beyond what's needed to branch UI/API behavior between ts (file-based) and go (DB-based) handoff sources.
- Do not modify `workflow-bff`'s proxy/routing logic itself — only add a routing-table entry for the new endpoint using the existing pass-through mechanism. No new BFF-side business logic, aggregation, or transformation.
