# Handoff — task-branch-lifecycle

**Feature:** Task branch lifecycle — claim, execution, and blocked recovery
**Completed:** 2026-04-15
**All tasks:** T1–T7 done (7/7)

---

## What was built

Closed three behavioural gaps in the agent-runtime orchestration loop that prevented
reliable task-branch management, management-repo PR tracking, and blocked-task recovery.

### Problem summary

| Gap | Before | After |
|-----|--------|-------|
| Claim commits | Directly to `main` — no task branch created by orchestrator | `claimTask` creates `feature/<featureId>-<taskId>` and pushes there |
| Management-repo PR | Never opened | Opened at claim time via `openWorkspacePr`; deduped on re-claim |
| Blocked recovery | Only `blocked_reason` text — no WIP location | `blocked_context` (`wip_branch`, `wip_sha`, `pushed_at`) written on both crash and graceful-block paths |

### New and changed components

| Component | Location | Change |
|---|---|---|
| `taskBranchName` helper | `agent-runtime/src/paths.ts` | New canonical branch-name helper; all callers use it |
| `BlockedContext` type | `agent-runtime/src/types/task.ts` | New interface; `blocked_context` + `workspace_pr` added to `Task` |
| `claimTask` rewrite | `agent-runtime/src/claim/claim-task.ts` | Creates task branch; handles 3 branch-exists cases; `branch_blocked_recovery` result |
| `openWorkspacePr` | `agent-runtime/src/claim/open-workspace-pr.ts` | New module; GitHub REST API PR creation + dedup via `curl` |
| `main.ts` wiring | `agent-runtime/src/main.ts` | Calls `openWorkspacePr` after claim; routes `branch_blocked_recovery` to S5 path |
| `writeBlockedAndPush` | `agent-runtime/src/loop/run-claude.ts` | Writes `blocked_context` on crash-block path (`git rev-parse HEAD`) |
| `start-implementation` SKILL.md | `workflow_skills/start-implementation/SKILL.md` | Management-repo checkout (not create); new blocked recovery mode section; updated blocking exit sequence |
| `TASK.template.yaml` | `templates/feature/tasks/TASK.template.yaml` | `branch: ""` (was hardcoded); `blocked_context: null`; `workspace_pr: null` |

### Claim sequence (new)

```
1. git fetch origin + reset --hard origin/main
2. Read task YAML; verify status === "ready"
3. branch = taskBranchName(featureId, taskId)
4. Check remote branch existence:
   a. NOT exists  → git checkout -b <branch>        (normal fresh claim)
   b. EXISTS, blocked_context null
              → git checkout <branch>               (interrupted prior claim)
                git reset --hard origin/<branch>
   c. EXISTS, blocked_context non-null
              → return { won: false, reason: "branch_blocked_recovery" }
5. Pre-commit jitter
6. Mutate YAML: status → in_progress, branch → derived name
7. git commit + push to <branch>  (SHA-contention detection on push rejection)
8. Post-claim verify
```

### Blocked recovery flow (S5)

When `branch_blocked_recovery` is returned:
1. Orchestrator emits `task_blocked_recovery_detected` and falls through to `runClaude`
2. Agent's `start-implementation` detects `blocked_context` non-null, checkouts the WIP branch on both repos
3. Reads `blocked_reason` + `suggested_next_step` as prior context
4. Appends `recovery_started` log entry, resumes implementation from WIP commits
5. On PR creation, clears `blocked_context: null`

### Test coverage added

- `tests/claim-task.test.ts`: branch-creation, branch-exists cases, `branch_blocked_recovery`, push contention (5-agent simulation)
- `tests/open-workspace-pr.test.ts`: GET dedup, POST creation, `parseGitHubCoords`, error cases
- `tests/run-claude.test.ts`: crash-block path writes `blocked_context`, fallback to `"unknown"` SHA, happy path leaves `blocked_context: null`
- `tests/integration/agent-runtime.integration.test.ts`: fixture updated with `blocked_context`/`workspace_pr` fields

**Total: 176 tests (up from 172). All passing. `tsc --noEmit` clean.**

---

## Key design decisions

**D1 — `claimTask` creates the branch (not `start-implementation`):**
All orchestrator git operations (log sink, blocked push) automatically land on the task
branch. Matches the product spec intent. `start-implementation` now checkouts the
pre-existing branch rather than creating it.

**D3 — Same SHA-comparison contention, applied to task branch:**
No new contention mechanism. First push to the new branch wins; subsequent pushers get
non-fast-forward rejection. Pre-commit jitter (50–500 ms) prevents simultaneous first-push races.

**D6 — Canonical branch always; new PR if prior one closed:**
`openWorkspacePr` always uses `feature/<featureId>-<taskId>` — no `-<attempt>` suffixes.
If the prior PR was closed, a new PR is opened on the same branch. The branch
accumulates the full commit history across recovery attempts.

---

## What is NOT done (out of scope)

- **S5 end-to-end integration test**: blocked recovery mode in `start-implementation`
  is documented (T6) but has no automated test. A future task should add an integration
  test that seeds a task with `blocked_context` and verifies the recovery path.
- **`flushLogAndPush` divergence guard**: if the agent subprocess pushes commits to the
  task branch and then the orchestrator's `flushLogAndPush` also pushes, a non-fast-forward
  can occur. Identified as an existing interleave risk; left for a future hardening task.
- **`workspace_pr` status tracking**: `openWorkspacePr` sets `status: "open"` but never
  updates it to `"merged"`. PR status is not polled or updated by the runtime.
