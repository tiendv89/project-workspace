# Technical Design

## Feature
- Feature ID: `reviewer-dispatch-hardening`
- Title: Reviewer dispatch hardening — reviewing status guard + executor env separation

## Current State

### Log-scan guards (three locations)

**`eligibility/match.ts` — `findReviewableTasks`** (line 492):
```ts
t.log[t.log.length - 1]?.action !== "reviewer_started"
```
Returns tasks eligible for reviewer dispatch. The log-scan predicate is the only guard against dispatching a second reviewer while one is already running.

**`pr/dispatch-reviewer.ts`** (line 142):
```ts
if (lastEntry?.action === "reviewer_started") { return "claim_lost"; }
```
Secondary guard inside `dispatchReviewer` — runs after fetching the latest task YAML. If this guard were the only one, concurrent orchestrators could still both pass it if neither had yet pushed a `reviewer_started` entry.

**`task/claim-fix.ts`** (line 79):
```ts
if (last?.action === "fix_started") return { won: false, reason: "already_claimed" };
```
Guard inside `claimFixTask`. `claim-fix.ts` already sets `task.status = "in_progress"` in the same claim commit (line 89) — the log scan is entirely redundant given that status check.

### Token / MCP audit gaps

**`dispatch-review-result.ts`**: writes `reviewer_complete` and `review_incomplete` log entries but never spreads `token_usage`, `cost_usd`, or `mcp_usage`. The `ReviewerResult` ABI type (`abi/src/types.ts`) does not define these fields.

**Fix executor reap path**: fix executor completions route to the `kind="impl"` branch of the reap loop, which calls `dispatch.ts`. `dispatch.ts` DOES write `token_usage`/`cost_usd` on `run_completed` and `blocked` entries — fix executor token tracking is already correct.

**RAG / GitNexus mid-session**: the executor extracts `rag_query` and `gitnexus_query` events from stdout after the run (`extractRagQueries`, `extractGitNexusQueries`) and emits them to the log sink (jsonl). These events are never placed in `result.json`, so the orchestrator never sees them and they never reach the task YAML. Only `rag_pre_flight` (written by the orchestrator before spawn) is visible in the task audit trail.

### `MAX_TURNS` pass-through

`main.ts` line 441:
```ts
MAX_TURNS: String(config.budget.max_iterations),
```
`config.budget.max_iterations` comes from the agent YAML (`budget.max_iterations`). The orchestrator reads this and injects it as `MAX_TURNS` in `extraEnv`. Because `SubProcessAdapter.submit()` builds `childEnv = { ...process.env, ...extraEnv, ...abivars }`, the executor receives `MAX_TURNS` through `extraEnv`.

The executor reads `process.env.MAX_TURNS ?? "200"`. Since `...process.env` is spread first and `...extraEnv` overwrites it, any ambient `MAX_TURNS` in the operator environment is overridden by the agent YAML value. This coupling between the agent YAML and the executor's turn budget is a hidden dependency.

`dispatch-reviewer.ts` also passes `MAX_TURNS: String(maxTurns)` from its `DispatchReviewerOptions.maxTurns` parameter.

## Problem Framing

**What specifically needs to change:**
1. `findReviewableTasks` log-scan predicate removed; status check (`reviewing` absent from results) is sufficient.
2. `dispatchReviewer` claim guard replaced with `task.status === "reviewing"` post-fetch check; claim commit sets `task.status = "reviewing"`.
3. `claimFixTask` log-scan guard replaced with `task.status === "in_progress"` (already set in the same commit).
4. `ReviewerResult` type extended with `token_usage`, `cost_usd`, `mcp_usage` (optional).
5. `dispatch-review-result.ts` spreads those fields on `reviewer_complete` and `review_incomplete` log entries.
6. Executor includes `mcp_usage` in `result.json`; same field spread by all reap paths.
7. `MAX_TURNS` removed from `extraEnv` in `main.ts` and `dispatch-reviewer.ts`; `MAX_TURNS` documented in docker-compose as an orchestrator-service env var (executor inherits via `...process.env`).
8. `CLAUDE.md` adds `reviewing` status, full transitions, explicit audit-only note for `reviewer_started`/`fix_started`.

**What must remain stable:**
- Fix executor token tracking (`dispatch.ts` `run_completed`/`blocked` entries) — already correct, no changes.
- `claim-fix.ts` SHA-based push contention resolution (lines 106–134) — not touched.
- `dispatchReviewResult` routing logic (`passed`/`change_requested`/`escalate`) — not touched.
- `check-in-review.ts` PR poll — not touched; it checks `status === "in_review"` which remains valid (reviewer sets task to `reviewing` before dispatch; `passed` result leaves task as `in_review` for PR poll to detect merge).
- Agent YAML `budget.max_iterations` field — remains valid; orchestrator still reads it for other internal budgeting (`budgetTokens`). Only the `MAX_TURNS` extraEnv injection is removed.

**Assumptions already fixed:**
- Fix executor (`kind="fix"`) routes through `kind="impl"` in the reap loop → `dispatch.ts` → token tracking already works.
- `SubProcessAdapter` spreads `...process.env` first — executor inherits the full orchestrator environment including any ambient `MAX_TURNS`.
- `reviewing` is a new status value; it does not exist in any current task YAML. No migration needed.

## Constraints

- `reviewing` must be added to the `TaskStatus` union in the orchestrator's task types before any dispatch code references it.
- Removing `MAX_TURNS` from `extraEnv` means the executor falls back to `process.env.MAX_TURNS ?? "200"`. Operators must set `MAX_TURNS` in docker-compose to preserve current behavior; the default 200 is safe but may differ from per-workspace agent YAML values.
- `reviewing` tasks must NOT be returned by `findReviewableTasks` — they are already claimed. The eligibility filter `status in [in_review, review_incomplete]` naturally excludes them.
- The `passed` result path in `dispatch-review-result.ts` leaves task status as `in_review` (the PR poll detects merge). After this feature, the reviewer runs while status is `reviewing`; when it finishes with `passed`, the orchestrator transitions the task back to `in_review` before the PR poll picks it up. This requires one additional status write in the `passed` branch of `dispatch-review-result.ts`.

## Options Considered

### Option A — Status-only guard (no log entry change)
Keep `reviewer_started` and `fix_started` log entries; just stop using them as dispatch guards. Replace all three log-scan predicates with status checks.

- Pros: minimal blast radius; log entries remain for historical context.
- Cons: log entries have no machine purpose — their continued presence creates maintenance confusion ("why do we still write these?").
- Chosen: Yes, but with CLAUDE.md explicitly documenting them as audit-only. Removing them is a separate future cleanup.

### Option B — Remove log entries entirely
Stop writing `reviewer_started` and `fix_started` in the claim commit.

- Pros: removes dead machine state.
- Cons: breaks existing log consumers that may display these entries; requires a bigger audit of all log readers; out of scope for this feature.
- Chosen: No — too broad. Log entries are retained as audit-only.

### Option C — Separate `mcp_usage` file per executor run
Write a `mcp_usage_<handle>.json` sidecar instead of embedding in `result.json`.

- Pros: doesn't widen the ABI contract.
- Cons: orchestrator needs a second file read per completion; more complex cleanup; doesn't flow naturally into the task log.
- Chosen: No — extend `result.json` and `ReviewerResult` directly.

## Chosen Design

**Option A for log guards** + extend ABI types for audit fields.

### 1. `reviewing` status — three-file change (workflow repo)

**`task/types.ts`** — add `"reviewing"` to `TaskStatus` union.

**`eligibility/match.ts` — `findReviewableTasks`:**
```ts
// Before
(t) => (t.status === "in_review" || t.status === "review_incomplete")
       && !!t.pr?.url
       && t.log[t.log.length - 1]?.action !== "reviewer_started"

// After
(t) => (t.status === "in_review" || t.status === "review_incomplete")
       && !!t.pr?.url
```

**`pr/dispatch-reviewer.ts`** — claim guard:
```ts
// Before (line 134-145): check task.status and lastEntry.action
if (task.status !== "in_review" && task.status !== "review_incomplete") { ... }
const lastEntry = task.log[task.log.length - 1];
if (lastEntry?.action === "reviewer_started") { return "claim_lost"; }

// After: status-only guards
if (task.status === "reviewing") {
  emit({ type: "reviewer_already_claimed", ... });
  return "claim_lost";   // <- actually "skip" semantics; see below
}
if (task.status !== "in_review" && task.status !== "review_incomplete") {
  emit({ type: "reviewer_claim_lost", details: `task status is ${task.status}` });
  return "claim_lost";
}
// Claim: set status = "reviewing" before push
task.status = "reviewing";
task.log.push({ action: "reviewer_started", ... }); // audit only
```

Note on "skip" vs "claim_lost": both return `"claim_lost"` to the caller for backward compatibility. The distinction (`reviewing` = already claimed vs `in_review` push-rejected = lost race) is captured in the emitted event type.

**`pr/dispatch-reviewer.ts`** — `passed` result: after reviewer completes with `passed`, the task must transition back to `in_review` for the PR poll to detect the merge. This transition is written in `dispatch-review-result.ts` `passed` branch:
```ts
case "passed": {
  // Reset status to in_review so the PR poll can detect merge.
  mutateTaskYamlDirect({ ..., status: "in_review", logEntry: { action: "reviewer_complete", ... } });
  ...
}
```

**`task/claim-fix.ts`** — fix-claim guard:
```ts
// Before (line 79)
if (last?.action === "fix_started") return { won: false, reason: "already_claimed" };

// After
if (task.status === "in_progress") return { won: false, reason: "already_claimed" };
```

### 2. Token and MCP audit (ABI + executor + dispatch-review-result)

**`abi/src/types.ts`** — extend `ReviewerResult`:
```ts
export interface ReviewerResult {
  terminal_status: ReviewerTerminalStatus;
  verdict: ReviewerTerminalStatus;
  confidence: number;
  notes: string;
  review_url?: string;
  self_review_skipped?: boolean;
  // New audit fields — optional; omitted when not available
  token_usage?: { input: number; output: number; model?: string };
  cost_usd?: number;
  mcp_usage?: {
    rag_queries: Array<{ query: string; result_length: number }>;
    gitnexus_queries: Array<{ tool: string; arguments: Record<string, unknown>; result_length: number }>;
  };
}
```

Add `mcp_usage` to `ExecutorResult` as well (impl and fix executors also produce it).

**`executors/claude/src/index.ts`** — after extracting RAG/GitNexus queries, include them in `claudeResult` before writing `result.json`:
```ts
const ragQueries = spawnResult.stdout ? extractRagQueries(spawnResult.stdout) : [];
const gitnexusQueries = spawnResult.stdout ? extractGitNexusQueries(spawnResult.stdout) : [];
if (ragQueries.length > 0 || gitnexusQueries.length > 0) {
  claudeResult.mcp_usage = { rag_queries: ragQueries, gitnexus_queries: gitnexusQueries };
}
```
The existing `emit({ type: "rag_query", ...rq })` calls remain for the log sink.

**`task/dispatch-review-result.ts`** — spread audit fields on all log entries:
```ts
// change_requested branch
logEntry: {
  action: "reviewer_complete",
  ...(result.token_usage && { token_usage: result.token_usage }),
  ...(result.cost_usd !== undefined && { cost_usd: result.cost_usd }),
  ...(result.mcp_usage && { mcp_usage: result.mcp_usage }),
  ...
}
// review_incomplete branch (default case)
logEntry: {
  action: "review_blocked",
  ...(result.token_usage && { token_usage: result.token_usage }),
  ...(result.cost_usd !== undefined && { cost_usd: result.cost_usd }),
  ...(result.mcp_usage && { mcp_usage: result.mcp_usage }),
  ...
}
// passed branch (new status reset entry)
logEntry: {
  action: "reviewer_complete",
  ...(result.token_usage && { token_usage: result.token_usage }),
  ...(result.cost_usd !== undefined && { cost_usd: result.cost_usd }),
  ...(result.mcp_usage && { mcp_usage: result.mcp_usage }),
}
```

**`task/dispatch.ts`** — `run_completed` and `blocked` entries: add `mcp_usage` spread (same pattern as existing `token_usage`/`cost_usd`).

### 3. `MAX_TURNS` env separation

**`main.ts`** — remove from `extraEnv`:
```ts
// Remove this line:
MAX_TURNS: String(config.budget.max_iterations),
```

**`pr/dispatch-reviewer.ts`** — remove `MAX_TURNS` from `extraEnv`; remove `maxTurns` parameter from `DispatchReviewerOptions`.

**`docker-compose.platform.yml` + `runtime/orchestrator/templates/docker-compose.local-docker.yml`** — add to orchestrator service `environment`:
```yaml
environment:
  MAX_TURNS: ${MAX_TURNS:-200}   # executor turn budget; inherited by all executor subprocesses
```

**`runtime/orchestrator/docs/OPERATOR-GUIDE.md`** — document `MAX_TURNS` as an operator env var set on the orchestrator service; not injected per-executor-spawn.

**`abi/docs/abi-spec.md`** — note that `MAX_TURNS` is executor-read via inherited environment, not an orchestrator-injected ABI variable.

### 4. CLAUDE.md (management-repo)

Add `reviewing` to task status values list. Update transition table:
```
in_review → reviewing         (orchestrator, when reviewer executor is dispatched)
reviewing → in_review         (orchestrator, when reviewer completes with passed — PR poll then detects merge)
reviewing → change_requested  (orchestrator, when reviewer completes with change_requested)
reviewing → review_incomplete (orchestrator, when reviewer exits without a valid result)
review_incomplete → reviewing (orchestrator, when re-dispatching on next cycle)
```
Replace `review_incomplete → in_review` with `review_incomplete → reviewing`.

Add explicit note to log actions table: `reviewer_started` and `fix_started` are **audit-only** — the orchestrator must not read these entries to make any dispatch decision.

## Dependency Analysis

- **Hard**: `TaskStatus` union in `task/types.ts` must include `"reviewing"` before `dispatch-reviewer.ts` or `match.ts` reference it — T2 (ABI/types) must land before T3 (log-scan removal).
- **Hard**: `ReviewerResult` type extension must land before `dispatch-review-result.ts` spreads the new fields — T2 before T4.
- **Soft**: CLAUDE.md (T1) and MAX_TURNS cleanup (T5) are independent of the type changes; can ship in any order.
- **No external dependencies** — all changes are within `workflow` and `management-repo`.

## Parallelization / Blocking Analysis

```
T1: management-repo — CLAUDE.md: reviewing status + transitions + audit-only note
  └── Can begin now — no blockers

T2: workflow — ABI types: reviewing in TaskStatus union; token_usage/cost_usd/mcp_usage in ReviewerResult + ExecutorResult
  └── Can begin now — no blockers
  └── T1 and T2 run in parallel
  │
  T3: workflow — Log-scan guard removal: match.ts + dispatch-reviewer.ts + claim-fix.ts
      └── BLOCKED on T2 (reviewing must be a valid TaskStatus before dispatch code uses it)

  T4: workflow — Token/MCP audit: dispatch-review-result.ts + dispatch.ts + executor/index.ts
      └── BLOCKED on T2 (ReviewerResult.token_usage/mcp_usage must exist before dispatch-review-result spreads them)
      └── T3 and T4 run in parallel (touch different files)

T5: workflow — MAX_TURNS cleanup: remove from extraEnv in main.ts + dispatch-reviewer.ts; docker-compose + OPERATOR-GUIDE.md
  └── Can begin now — no blockers
  └── T5 runs in parallel with T1, T2, T3, T4

        T6: workflow — Tests: reviewing guard paths; token/MCP audit paths; MAX_TURNS inheritance
              └── BLOCKED on T3 (log-scan removal must be in place to test new guard)
              └── BLOCKED on T4 (token/MCP audit must be in place to test)
              └── BLOCKED on T5 (MAX_TURNS removal must be in place to test env inheritance)
```

## Repository Impact

| Repo | Why touched |
|---|---|
| `management-repo` | CLAUDE.md: add `reviewing` status, update transition table, mark log actions audit-only |
| `workflow` | `abi/src/types.ts`: type extensions; `eligibility/match.ts`, `pr/dispatch-reviewer.ts`, `task/claim-fix.ts`: log-scan removal; `task/dispatch-review-result.ts`, `task/dispatch.ts`, `executors/claude/src/index.ts`: token/MCP audit; `main.ts`, docker-compose: MAX_TURNS cleanup; tests |

## Validation and Release Impact

**Tests required (`workflow` repo):**
- `findReviewableTasks` returns `in_review` and `review_incomplete` tasks regardless of last log entry; does not return `reviewing` tasks.
- `dispatchReviewer`: task already `reviewing` after fetch → returns `claim_lost` without push; task `in_review` → claim sets status `reviewing`, pushes, submits executor; push rejected → `claim_lost`.
- `claimFixTask`: task `in_progress` after fetch → returns `already_claimed`; `change_requested` with no prior claim → wins.
- `dispatchReviewResult`: `change_requested` result with `token_usage`/`mcp_usage` → log entry has those fields; `review_incomplete` → same; `passed` → task status reset to `in_review`.
- Executor `mcp_usage`: `result.json` contains `mcp_usage` when RAG/GitNexus calls present in stdout; absent otherwise.
- `MAX_TURNS` not present in any `extraEnv` construction in orchestrator code (static grep check in test).

**Migration / config impact:**
- Existing tasks with `status: "in_review"` — unaffected; `reviewing` is a new forward-only status.
- `MAX_TURNS` env var: operators must set `MAX_TURNS` in docker-compose (or their operator env) to match their current agent YAML `budget.max_iterations` value. If not set, executor defaults to 200. This is a required ops step on upgrade.
- `ReviewerResult` type extension is backward-compatible — all new fields are optional.

**Rollout:**
- T1 (CLAUDE.md) can ship independently.
- T2–T6 ship together in the `workflow` repo; no feature flag needed.
- The `MAX_TURNS` change requires an ops step (docker-compose update) before deploying T5.

**Backward compatibility:**
- `reviewer_started` and `fix_started` log entries remain in existing task YAMLs — they are now audit-only. Nothing reads them for dispatch decisions after this ships.
- Tasks currently `in_review` with a `reviewer_started` last-log entry: after this ships, `findReviewableTasks` will return them (log scan removed). The `dispatchReviewer` post-fetch check will see `in_review` (not `reviewing`) and proceed normally.
