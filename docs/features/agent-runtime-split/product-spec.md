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
| `TASK_REPO_URL` | Git URL of the implementation repo (SSH or HTTPS). |
| `TASK_REPO_BRANCH` | Feature branch the executor must be on when it makes commits. |
| `TASK_REPO_PATH` | Working-directory path. The **executor** materializes the repo here: if the path already exists with `origin` matching `TASK_REPO_URL`, fetch + checkout + pull; otherwise clone fresh from `TASK_REPO_URL`. The orchestrator may pre-populate this path as an optimization in shared-filesystem topologies, but it is not required to. |
| `BRIEFING_PATH` | Markdown file: task description, quality bar, anything task-specific the executor needs. Orchestrator-written. |
| `RESULT_PATH` | File path the executor writes its structured outcome to. |
| `BUDGET_TOKENS` | Optional; may be unset for non-LLM executors. |
| `SSH_KEY_PATH`, `GITHUB_TOKEN` | Credentials to clone, fetch, push, and (later) call GitHub if needed. |

**Why URL + branch + path, not just a path:** the orchestrator and the
executor may run in different filesystems (e.g. separate K8s pods, a
queued worker pool, a remote VM). A path passed by the orchestrator
has no meaning across that boundary. Passing `TASK_REPO_URL` +
`TASK_REPO_BRANCH` makes the contract topology-agnostic — the
executor materializes the repo wherever it runs. `TASK_REPO_PATH`
is still part of the ABI because the orchestrator dictates the
working-directory location (so it knows where to find code commits
afterwards if needed for verification, and so the briefing can refer
to a stable path) — but the executor, not the orchestrator, is the
authoritative actor that ensures the working tree is in the right
state.

**Why no `MGMT_REPO_PATH`:** per D5, the executor never reads or
writes the management repo — orchestrator owns all workflow-state
mutations (task YAML, PR open, log entries, dependency unblock).
Passing the management repo to the executor would imply
responsibilities the executor must not have. Removed from the ABI.

**Outputs the executor must produce:**

- An exit code (0 = ran to completion, non-zero = crashed or otherwise failed).
- Code commits pushed to the feature branch on the impl repo.
- An open pull request on the impl repo from the feature branch
  whenever the executor has commits to PR. Opening is **not** gated on
  the executor's internal quality gate — see D5. The executor uses
  `GITHUB_TOKEN` to open it.
- A `result.json` at `RESULT_PATH`:
  ```json
  {
    "terminal_status": "in_review" | "blocked" | "failed",
    "pr_url": "https://github.com/owner/repo/pull/123",
    "token_usage": { "input": 0, "output": 0 },
    "blocked_reason": "...",
    "blocked_suggestion": "..."
  }
  ```
  - `pr_url` is reported whenever the executor opened an impl PR —
    independent of `terminal_status`. A blocked task with a draft PR
    documenting the failed attempt still carries `pr_url`. The
    orchestrator records it in the task YAML's `pr.url` field.
  - The executor's internal quality gate (e.g. tests) is the
    executor's own responsibility and is reflected only via
    `terminal_status`. Gate failure → `terminal_status: "blocked"`
    with `blocked_reason: "tests_failed"` (or whatever applies); the
    PR still exists and `pr_url` is still reported. The orchestrator
    never inspects the gate; it only sees `terminal_status` and
    `pr_url`.

The executor does **not** push workflow-state commits, mutate task
YAML, or open the management/workspace PR — those are orchestrator
responsibilities (see D5).

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
- Materialize the task repo at `TASK_REPO_PATH` from `TASK_REPO_URL`
  on `TASK_REPO_BRANCH` (clone or fetch + checkout).
- Read its briefing.
- Modify code in the working tree.
- Commit and push the code changes to `TASK_REPO_BRANCH`.
- Apply whatever internal quality gate it considers required (tests,
  lint, type-check, manual checks — entirely up to the runtime).
- Open an implementation PR on the impl repo (`TASK_REPO_URL`) using
  `GITHUB_TOKEN` provided in the ABI, whenever there are commits to
  PR — regardless of whether the quality gate passed. The PR is part
  of the task lifecycle, not an artifact of "did the work succeed".
- Write `result.json` with the appropriate `terminal_status` and
  `pr_url` (always populated when a PR was opened):
  - Gate passed: `terminal_status: "in_review"`, `pr_url: "..."`.
  - Gate failed: `terminal_status: "blocked"`,
    `blocked_reason: "tests_failed"` (or equivalent), `pr_url: "..."`
    (the PR documents the failed attempt, possibly as draft).

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

### D5. Workflow side effects are owned by orchestration (revised)

> **Revision note (2026-05-02):** the original D5 stated "orchestrator opens
> the PR. Runtimes never call `pr-create`." During implementation it became
> clear this conflated two different PRs — the **implementation PR** (code
> in the impl repo) and the **management/workspace PR** (task YAML state
> change in the management repo). The executor has rich context for the
> impl PR (diff, test results, change rationale); the orchestrator has the
> workflow-state context for the workspace PR. Forcing both onto a single
> owner discards context. D5 is revised below to split the two.

**Implementation PR (impl repo, e.g. `agent-workflow`):**

- **Opened by the executor.** The executor has the full diff and test
  context, so it owns the PR title, body, test plan, and change summary.
- **Opening is not gated on implementation outcome.** As soon as the
  executor has commits to PR, it opens the impl PR — whether the work
  succeeded, failed tests, or got stuck. The PR existing is part of
  the task lifecycle (same as the workspace PR opened at claim time);
  it is not an artifact of "did the work succeed". A blocked task with
  a draft PR documenting the failed attempt is more useful than no PR
  at all.
- `terminal_status` reflects the **work** status (`in_review` = work
  is ready for review; `blocked` = work hit a gate it couldn't pass),
  not the PR's existence. `pr_url` is reported in `result.json`
  whenever the executor opened a PR — regardless of `terminal_status`.
- The orchestrator records `pr_url` whenever it's present and
  translates `terminal_status` into task YAML state. It does not
  inspect the executor's internal quality gate.

**Management / workspace PR (management repo):**

- **Opened by the orchestrator.** This PR contains task YAML state
  changes (`in_progress` → `in_review` / `blocked`, log entries, branch
  field, `pr` field, `workspace_pr` field). It is opened at claim time
  and updated as the task progresses.
- The orchestrator owns its title, body, and lifecycle.

**Workflow-state mutations (always orchestrator-owned):**

- Task YAML mutations (status transitions, log entries, branch field,
  pr field, workspace_pr field) — derived from `result.json`.
- Dependency unblock — orchestrator applies the auto-ready rule when a
  task is marked `done`.
- **No quality gating in the orchestrator.** Per D4, the orchestrator
  is pure workflow-state code — it does not know what "tests" mean,
  whether they ran, or whether they passed. The executor's internal
  quality gate (tests, lint, type-check, anything else) is owned
  entirely by the executor. The executor reports the resulting
  `terminal_status` and the orchestrator translates it into task YAML
  state. If tests fail inside the executor, the executor reports
  `blocked` with an appropriate `blocked_reason`; the impl PR is
  still opened (as draft, or with a failure-summary comment) so the
  failed attempt is documented, and the orchestrator simply applies
  the `blocked` state.

**Code commits:** pushed by the executor on the feature branch. Commit
messages are freeform; the canonical record is the executor-authored
PR title.

**Practical note:** custom runtimes (e.g. a future Hermes executor) must
implement PR creation against the implementation repo using the
`GITHUB_TOKEN` already provided by the ABI. This is part of the executor
contract, not optional. A runtime that cannot open PRs is not ABI-conformant.

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
