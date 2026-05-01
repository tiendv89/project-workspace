# Product Specification

## Feature
- Feature ID: `agent-runtime-split`
- Title: Split agent runtime into orchestration and execution layers

## Problem

Today the agent runtime (`workflow/agent-runtime/`, ~6.7k LOC) is a single Node.js
process that interleaves two very different responsibilities in one event loop:

1. **Orchestration** — discovering eligible tasks across watched workspaces,
   pulling repos, claiming tasks via the git-SHA protocol, polling GitHub for
   PR merges/conflicts, advancing task YAML state, opening and merging
   workspace PRs, enforcing dependency unblocks, writing audit logs.

2. **Execution** — generating a per-task agent briefing, spawning the
   `claude -p` subprocess inside the same container, capturing stdout, parsing
   token usage, and persisting the resulting task YAML mutations.

Concrete entanglement points:

- `agent-runtime/src/main.ts` owns the polling loop **and** dispatches Claude
  invocations from the same scope (imports `runAgentLoop`,
  `pullWorkspaces`, `checkInReviewPrs`, `handleMergeConflicts` side-by-side).
- `loop/run-claude.ts` requires `workspaceRoot`, `taskRepoRoot`, and
  `agentContext` — all orchestration-discovered state — to run.
- Token-budget enforcement straddles both layers: orchestration reads
  `budget.max_tokens_per_task` during eligibility, execution audits it
  post-exit.
- The runtime is hard-coded to `claude` as a binary. There is no abstraction
  point at which a different executor (e.g. Hermes / NousResearch) can be
  plugged in. The `agent-runtime-selector` feature already declared a
  task-level `execution.runtime: claude-code | hermes` field, but the runtime
  has nowhere to dispatch on it.

This coupling causes four concrete pains documented in the prior agent-runtime
features:

- **Cannot swap or mix executors.** Every task pays Claude API cost regardless
  of complexity (`agent-runtime-selector/product-spec.md`: "Many tasks in the
  workflow are routine and mechanical … where a cheaper or free runtime would
  produce equally good output.")
- **Cannot scale orchestration independently.** One container == one polling
  loop == one executor. Running N agents means running N copies of the
  orchestration loop, each independently polling GitHub and re-discovering
  the same task pool.
- **Cannot test orchestration without invoking the LLM.** Eligibility scan,
  claiming, PR polling, dependency-unblock — all of these are pure logic but
  cannot be exercised without the full runtime image.
- **Operational fragility from mixed concerns.** Docker restart-backoff
  silently degrades the polling loop (`agent-runtime-polling-loop`); a
  Claude crash takes down the orchestration loop with it.

## Goals

- **G1.** Define a clean orchestration ↔ execution contract — a single,
  documented interface across which orchestration hands a claimed task to an
  executor and receives back a terminal state (`in_review`, `blocked`, or
  failure) plus token/usage metadata.
- **G2.** Extract orchestration into a layer that can run independently of
  any executor: poll workspaces, scan eligibility, claim tasks, monitor PRs,
  unblock dependents, advance task YAML, drive the PR-merge handoff.
- **G3.** Extract execution into a layer that takes one claimed task as input
  and is responsible only for producing the work product (commits, PR, task
  YAML mutations on the feature branch).
- **G4.** Make the executor pluggable so a task with
  `execution.runtime: claude-code` runs through the Claude executor and
  `execution.runtime: hermes` runs through the Hermes executor — without the
  orchestration layer needing to know which.
- **G5.** Preserve full functional parity with today's runtime on day 1: no
  task that works today should fail after the split, and no new manual steps
  should be introduced for operators.

## Non-goals

- **N1.** Implementing the Hermes executor itself. That is a separate
  feature; this spec only requires that the contract makes a Hermes executor
  trivially droppable.
- **N2.** Multi-tenant isolation, billing, or per-tenant policy. Out of
  scope for this split — the layers stay single-tenant on day 1.
- **N3.** Replacing the git-SHA claim protocol or the management-repo state
  model. The split must work over the existing protocol.
- **N4.** Moving orchestration to a hosted/managed service (e.g. running it
  as a long-lived cloud service vs. a container). Day 1, both layers can
  still run inside one container if that is what the operator wants — the
  split is logical first, deployable separately second.
- **N5.** Changing the task YAML schema or the workspace.yaml schema.
- **N6.** Building a UI for the split. Existing dashboards keep working.

## Success criteria

- A task claimed by the orchestration layer can be executed by **any**
  executor implementing the contract, with no orchestration-side code
  changes.
- The orchestration layer can be exercised end-to-end (eligibility, claim,
  PR poll, merge handoff, dependency unblock) in tests with a fake/no-op
  executor — no `claude` binary needed.
- The execution layer can be invoked standalone for a single claimed task
  (e.g. for replay, debug, or local dry-run) without the polling loop
  running.
- Existing operators can deploy the split runtime with **at most one** new
  config knob (executor selection) and keep all current Docker / K8s /
  systemd templates working.
- Token-budget enforcement still happens; the contract makes its location
  unambiguous (executor reports usage, orchestration audits against budget).

## User stories

- *As an operator,* I can run the orchestration layer alone in a small
  container that only watches workspaces and updates state, and route
  execution to a separate worker pool.
- *As a workflow author,* I can mark a routine task `execution.runtime: hermes`
  and trust that the orchestration layer will dispatch it correctly without
  any change to my task YAML structure.
- *As an agent-runtime maintainer,* I can change Claude prompt assembly
  without touching any orchestration code.
- *As a reviewer,* I can read the orchestration contract in one file and
  understand the full lifecycle of a task without reading executor code.

## Architecture decisions (resolved during spec discussion)

These were Q1–Q6 in the original draft. They are settled here so the technical
design can build on them. They are listed as decisions rather than questions
because each has been agreed; the technical design phase will operationalize
them, not relitigate them.

### D1. Logical split first; deployment topology is a knob

Day 1 ships as a logical split — two layers in the same monorepo, the
default deployment running both inside one container (same as today). The
contract is designed so that swapping the in-process call for a separate
container, a Kubernetes Job, or a queued worker pool is a deployment-level
change, not a code rewrite.

We are not introducing a queue, a broker, or new concurrency primitives on
day 1. The existing git-SHA claim protocol continues to arbitrate
contention across multiple orchestrator instances exactly as it does today.

### D2. The contract is a container ABI, not a function call

An executor is defined by what it consumes and produces, not by what
language or framework it is built in. Anyone who can produce an image
respecting the ABI is a valid runtime.

**Inputs the orchestrator passes to the executor at start** (env vars +
mounted files):

| Variable | Description |
|---|---|
| `TASK_ID`, `FEATURE_ID`, `WORKSPACE_ID` | Task identity. |
| `TASK_REPO_PATH` | Pre-cloned implementation repo, already on the task's feature branch. |
| `MGMT_REPO_PATH` | Pre-cloned management repo, already on the feature branch. |
| `BRIEFING_PATH` | Markdown file: task description, quality bar, anything task-specific the executor needs. |
| `RESULT_PATH` | File path the executor writes its structured outcome to. |
| `BUDGET_TOKENS` | Optional; may be unset for non-LLM executors. |
| `SSH_KEY_PATH`, `GITHUB_TOKEN` | Credentials to push code commits and (later) call GitHub if needed. |

**Outputs the executor must produce:**

- An exit code (0 = ran to completion, non-zero = crashed or otherwise failed).
- A `result.json` at `RESULT_PATH`:
  ```json
  {
    "terminal_status": "in_review" | "blocked" | "failed",
    "token_usage": { "input": 0, "output": 0 },
    "blocked_reason": "...",
    "blocked_suggestion": "..."
  }
  ```
- Code commits pushed to the feature branch. The executor pushes code
  changes only — it does not push workflow-state commits, it does not open
  PRs, it does not mutate task YAML.

The orchestrator calls the executor through a thin TypeScript seam
(`ExecutorAdapter.run(input) → result`) which wraps the ABI. In-process
adapters call the executor directly; out-of-process adapters spawn a
container or submit a job. Same interface in both cases.

### D3. Workflow protocol lives in orchestration, not in runtimes

The current `CLAUDE.md` conflates two things: (a) workflow rules — claim
commits, branch naming, task YAML schema and transitions, log format,
PR title format, dependency unblock, branch sync protocol, write-only-your-
own-task-YAML, test-before-PR; and (b) how to do good work on a task.

After the split, (a) is **orchestrator's job**, encoded in deterministic
code, never injected into a runtime's context. (b) is what the briefing
markdown carries.

A custom runtime built by someone else does not have to learn or honour
any of the workflow rules. It only has to:
- Read its briefing.
- Modify code in `TASK_REPO_PATH`.
- Commit and push the code changes.
- Write `result.json`.

### D4. Orchestrator is pure deterministic code; no LLM lives in it

The orchestrator does not call any model. Every decision it makes is
`if X then Y` logic: workspace pulls on a timer, eligibility filtering,
git-SHA claim, briefing templating, executor dispatch, result.json
translation, status mutation, PR open, auto-ready unblocks, PR-merge
handoff, GitHub REST polling.

If a future feature needs a non-deterministic judgment (e.g. summarising
a diff for a PR description), the orchestrator dispatches a small executor
task for it. It does not embed an LLM client.

Operational consequence: the orchestrator image is tiny (Node.js + git +
GitHub token). All language toolchains and agent frameworks live with the
executor images that need them.

### D5. Workflow side effects are owned by orchestration

- **Task YAML mutations** (`in_progress` → `in_review` / `blocked`, log
  entries, branch field, pr field): orchestrator writes them, derived
  from `result.json`.
- **PR open**: orchestrator opens the PR with the title and body
  conventions. Runtimes never call `pr-create`.
- **Dependency unblock**: orchestrator applies the auto-ready rule when a
  task is marked `done`.
- **Test-before-PR gating**: enforced by orchestrator (either by running
  tests itself or by requiring the executor to report a `tests_passed`
  boolean in `result.json` — to be settled in technical design).
- **Code commits**: pushed by the executor on the feature branch. The
  executor's commit messages are freeform; the canonical record is the
  orchestrator-authored PR title.

### D6. Runtime parity

Every runtime — Claude, Hermes, a python script, a future custom image —
implements the **same** ABI. There is no Claude-shaped contract and a
Hermes-shaped contract; there is one contract. Differences in capability
(e.g. one runtime may not consume token budget, another may not produce
PR-ready diffs) are expressed in the briefing, not in the contract surface.

### D7. Failure semantics

- Executor exits 0 + writes valid `result.json` → orchestrator applies the
  declared terminal status.
- Executor exits non-zero or fails to write `result.json` → orchestrator
  marks the task `blocked` with reason `executor_crashed`. The claim stays
  on the feature branch (same as today when Claude crashes); a human
  resolves it.
- Executor exceeds wall-clock or budget → orchestrator kills the executor
  process / job and marks `blocked` with reason `executor_timeout` or
  `executor_over_budget`.

### D8. Token-budget location

- Pre-dispatch: orchestrator refuses to dispatch a task whose
  `budget.max_tokens_per_task` is missing or invalid.
- Post-hoc: executor reports actual usage in `result.json`; orchestrator
  records it in the task log and surfaces budget overruns in the
  dashboard.
- No mid-run hard-stop from outside. If we ever need that, it is an
  executor-internal concern (e.g. Claude's `--max-turns`).

### D9. Single-cutover migration

The split ships as one clean release. The legacy monolithic runtime is
retired in the same release; there is no feature flag and no dual-run
period.

Rationale: the project is in alpha, backward compatibility is not a
concern, and the split is largely a refactor — same git-SHA claim
protocol, same Claude binary inside the executor, same `claude -p`
invocation surface. Risk is concentrated in the orchestrator ↔ executor
seam, which is best mitigated by exercising it in tests against a fake
executor before deployment, not by carrying two execution paths in
production.

The single-cutover assumption is valid only as long as N1 holds (Hermes
is **not** introduced in this release). If the scope grows to include a
second executor lighting up at the same cutover, this decision must be
revisited.

### D10. Repo placement: top-level `runtime/` tree in the workflow repo

The agent runtime is promoted to a top-level directory in the workflow
repo:

```
workflow/runtime/
  orchestrator/        # deterministic orchestration code; ships as its own image
  executors/
    claude/            # the first executor; ships as its own image
    # future executors land here as siblings
  abi/                 # ABI spec doc + shared TypeScript types
                       # + fixture/no-op executor used in orchestrator tests
```

Rationale: this signals the architectural shift away from "the runtime
is one thing" without taking on the operational weight of separate
repos in alpha. It makes the ABI a first-class artifact (a directory
with a spec doc and shared types) rather than something implicit in the
orchestrator's source. Single-repo CI still works, and lockstep
orchestrator + executor changes can ship in one PR when the ABI moves.

The existing `workflow/agent-runtime/` directory is renamed and
restructured as part of the cutover release; deploy templates (Docker,
K8s, systemd, GitHub Actions) and image references are updated in the
same change.

Future direction (out of scope here): when a third-party or
out-of-tree executor is introduced, that executor moves to its own
repo. The ABI directory's spec + version contract is what makes that
extraction safe — it is the published interface a separate-repo
executor would pin against.

## Open questions for discussion

_All open questions raised during spec discussion (Q1–Q8) have been
resolved into decisions D1–D10. None remain._

## Dependencies and risks

- No upstream feature dependencies. `agent-runtime-selector` is **not** a
  dependency — that feature builds on top of this one (the selector's
  per-task runtime routing becomes a simple lookup in the orchestrator's
  runtime registry once the ABI exists). Any selector-related concerns
  raised during this spec discussion are recorded under the selector
  feature, not here.
- Risk: a too-narrow contract bakes in Claude assumptions and makes
  later runtimes (e.g. Hermes) painful to add. Mitigation: design the
  contract with at least one sketch of a non-Claude executor on paper
  before committing.
- Risk: regression in claim/race correctness during refactor. Mitigation:
  extract orchestration with its current tests intact; only then introduce
  the executor abstraction.
