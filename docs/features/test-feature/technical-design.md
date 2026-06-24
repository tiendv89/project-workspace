# Technical Design

## Feature
- Feature ID: `test-feature`
- Title: Test Feature

## Current State

The workspace (`tiendv89/project-workspace`) is configured with a single management repo and sixteen indexed repositories across the SwellNetwork GitHub organisation (e.g. `voyager-backend`, `voyager-interface`, `voyager-mobile`, `voyager-user-service`, `faro-workspace`, `faro-alert-engine`, etc.). The Hermes feature lifecycle tooling — product spec → technical design → task breakdown → handoff — is operational but has not yet been exercised end-to-end in this workspace. There is no existing baseline test to confirm that:

- `status.yaml` transitions correctly through every stage
- GitNexus can resolve symbols from indexed repos during the design phase
- The management repo branch/PR wiring produces a clean, mergeable PR at handoff

**Note:** RAG and GitNexus returned no indexed results for the `test-feature` domain during context-gathering. This is expected — the feature does not touch production code. The open symbol/repo questions are listed under "Open Questions" below.

## Constraints

- No production code may be modified in any indexed implementation repo
- All document writes must land on the feature branch (`feature/test-feature-init`), never directly on `main`
- The management repo is `tiendv89/project-workspace` — it is the only repo in `workspace.yaml`
- Task files must follow the one-task-per-repo rule; since only the management repo exists in `workspace.yaml`, all tasks target it
- The feature must complete the full lifecycle (product spec → technical design → tasks → handoff) to serve as a valid smoke-test

## Options Considered

### Option A — Single documentation-only task
Create one task that verifies workflow tooling by writing a trivial markdown file to the management repo feature branch, then marks itself done.

- **Pros:** Minimal surface area; fast to execute; easy to review
- **Cons:** Does not exercise parallel task execution or dependency resolution; limited regression value

### Option B — Multi-task sequential chain
Create three sequential tasks (T1 → T2 → T3), each writing a small artifact to the management repo branch, with explicit `depends_on` wiring to validate the dependency/auto-ready mechanism.

- **Pros:** Exercises dependency resolution, auto-ready rule, and sequential claim/execution; better regression coverage
- **Cons:** Slower; more YAML to maintain; overkill for a smoke-test

### Option C — Two-task parallel + one sequential (chosen)
Create two independent tasks (T1, T2) that can run in parallel, followed by one task (T3) that depends on both. This exercises parallel dispatch, dependency resolution, and the auto-ready rule in a single feature — the minimum configuration needed to validate the full orchestrator loop.

- **Pros:** Covers parallel execution, dependency unblocking, and sequential handoff in one pass; realistic orchestrator workload without production risk
- **Cons:** Slightly more complex than Option A; still low overall complexity

## Chosen Design

**Option C** — two parallel documentation tasks followed by one dependent aggregation task, all targeting the management repo.

### Task structure

| Task | Title | Depends on | Actor |
|------|-------|------------|-------|
| T1 | Write smoke-test artifact A | — | agent |
| T2 | Write smoke-test artifact B | — | agent |
| T3 | Write smoke-test summary | T1, T2 | agent |

### Artifacts

- **T1** writes `docs/features/test-feature/smoke/artifact-a.md` — a minimal markdown file confirming T1 executed successfully
- **T2** writes `docs/features/test-feature/smoke/artifact-b.md` — a minimal markdown file confirming T2 executed successfully
- **T3** writes `docs/features/test-feature/smoke/summary.md` — aggregates the outputs of T1 and T2 and records the feature completion timestamp

All writes land on the feature branch. No files outside `docs/features/test-feature/` are modified.

### Lifecycle validation checkpoints

1. T1 and T2 activate as `ready` when tasks are approved (zero dependencies)
2. T1 and T2 execute in parallel (claim commits, artifact writes, `in_review` → `done`)
3. When both T1 and T2 are `done`, T3 auto-advances from `todo` to `ready`
4. T3 executes, writes `summary.md`, moves to `in_review` → `done`
5. Handoff PR is opened; human approves; feature moves to `done`

## Dependency Analysis

- **T1** — no dependencies; activates immediately on task approval
- **T2** — no dependencies; activates immediately on task approval (parallel with T1)
- **T3** — depends on T1 and T2; must not start until both are `done`
- All tasks target the management repo (`tiendv89/project-workspace`); no cross-repo dependency exists
- No external service dependencies (no DB migrations, no API changes, no infrastructure provisioning)

## Parallelization / Blocking Analysis

- T1 and T2 are fully independent and can be dispatched concurrently by the orchestrator
- T3 is blocked until both T1 and T2 complete; the auto-ready rule handles the transition
- No shared file contention risk: T1 writes `artifact-a.md`, T2 writes `artifact-b.md`, T3 writes `summary.md` — all distinct paths
- The management repo task YAML files (T1.yaml, T2.yaml, T3.yaml) are also distinct paths, so parallel claim commits do not conflict

## Open Questions

1. **GitNexus indexing coverage** — RAG and GitNexus returned no results for the `test-feature` domain. This is expected for a documentation-only feature. If future features fail to resolve symbols, the GitNexus index staleness should be investigated (`voyager-interface` is currently 1 commit behind HEAD).
2. **Management repo as sole `workspace.yaml` repo** — Only `management-repo` is declared in `workspace.yaml`. If implementation tasks targeting other repos are needed in future features, those repos must be added to `workspace.yaml` before the task breakdown phase.
