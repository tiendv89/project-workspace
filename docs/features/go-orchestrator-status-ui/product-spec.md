# Product Specification (backlog stub)

## Feature
- Feature ID: `go-orchestrator-status-ui`
- Title: Digital Factory UI — surface go-orchestrator features/tasks and go-specific statuses
- Owner: **TBD** (go vs ts — decide during grooming; see open questions)

> This is a backlog stub. It captures the known problem and the open questions only. Do not draft a
> technical design or task breakdown until it is groomed and approved. Split out of
> `go-orchestrator-ui-integration` (see that feature for the go-orchestrator task-creation pipeline).

## Problem

`digital-factory-ui` does not represent the Go/Postgres orchestrator's features and tasks distinctly
from the legacy TypeScript/git ones, even though the data model already carries the distinction:

- **Owner is invisible.** `owner: "ts" | "go"` exists on `FeatureSummary` / `FeatureDetail`
  (`src/services/workflow-backend/types.ts`) but is not read or branched on anywhere in the board or
  task components — no owner badge, no filter, no data-source distinction. A human cannot tell a
  go-owned feature from a ts-owned one in the UI.
- **Go-specific statuses are unrendered.** The go orchestrator uses task statuses that the board/task
  views do not display or handle: `reviewing`, `review_passed`, `review_incomplete`, and the
  `blocked_details` field. These states are effectively invisible to a human monitoring work in the UI.

The effect: once go-orchestrator work is running (see `go-orchestrator-ui-integration`,
`go-orchestrator-autonomy`), a human cannot properly observe or triage it from the board.

## Goals (draft — to refine during grooming)

- Distinguish go-owned features/tasks in the board/task views (e.g. an owner badge and/or filter).
- Render the go-specific task statuses (`reviewing`, `review_passed`, `review_incomplete`) and surface
  `blocked_details` where a task is blocked.
- Consume existing read APIs — do not duplicate the read layer (`workspace-data-backend` /
  `workflow-backend` read endpoints already established).

## Non-goals (draft)

- Human *actions* from the UI (approve/reject/unblock/retry) — this stub is about **visibility** only
  unless grooming decides otherwise. (The unblock UI is separately noted as out-of-scope/deferred in
  `go-orchestrator-autonomy`, whose bff endpoint would be the contract it consumes.)
- The go task-creation pipeline itself — owned by `go-orchestrator-ui-integration`.

## Open questions (resolve during grooming)

- **Owner (go vs ts)** for this feature's own task tracking — deferred.
- **Read source of truth**: which existing read API the board should consume for go features/tasks
  (`workspace-data-backend` vs a `workflow-backend` read endpoint) — confirm and reuse, don't rebuild.
- **Scope**: visibility only, or also human actions (unblock/retry/approve) from the board? If actions
  are included, does this feature consume `go-orchestrator-autonomy`'s deferred unblock bff endpoint?
- **Status representation**: how each go-specific status maps to existing board columns/badges, and how
  `blocked_details` is surfaced (inline, tooltip, detail panel).
- **Figma**: is there a design for the owner badge / status rendering? If so, propagate per the Figma
  link rules before implementation.

## Related
- `go-orchestrator-ui-integration` — the go task-creation pipeline this feature complements.
- `go-orchestrator-autonomy` — defines go-specific statuses and the deferred unblock UI contract.
