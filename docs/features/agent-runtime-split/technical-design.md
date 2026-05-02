# Technical Design

## Feature
- Feature ID: `agent-runtime-split`
- Title: Split agent runtime into orchestration and execution layers

This document operationalizes decisions D1–D10 from `product-spec.md`. It does
not relitigate them; it commits to a code-level shape, names the open
sub-decisions, and lays out the migration sequence.

> RAG note: RAG MCP server (`mcp__rag-server__rag_query`) was not connected at
> the time this design was authored. Per `rag-context` graceful-degradation,
> the design proceeds without retrieved context. The relevant context for this
> design is captured directly in the product spec discussion log.

---

## 1. Current state

The agent runtime today is a single Node.js process at
`workflow/agent-runtime/` (~6.7k LOC, 25 TypeScript files), bundled into one
Docker image that contains the Claude Code CLI plus every language toolchain
a task might need (python, go, cargo, yarn, …).

Concrete layout:

```
workflow/agent-runtime/
  src/
    main.ts                    # polling loop entry; calls all of the below
    bootstrap/
      bootstrap.ts             # clone + pull workspaces; populate env
      agent-context.ts         # generates the briefing markdown for Claude
    eligibility/match.ts       # pure: filter ready tasks by skills + deps
    claim/claim-task.ts        # git-SHA atomic claim protocol
    poll/                      # workspace pulls, PR-merge poll, conflict handler
    loop/run-claude.ts         # spawns `claude -p`, audits tokens, exits
  Dockerfile                   # bundles Node + Claude CLI + every toolchain
  templates/                   # docker-compose, K8s CronJob, systemd, GH Actions
```

Workflow-state writes today are split: orchestration code writes claim
commits; the Claude subprocess (via `pr-create`, branch-checkout-protocol
guidance from `CLAUDE.md`, and direct YAML edits) writes task YAML
mutations, opens PRs, and applies dependency unblock from inside the LLM's
turn loop.

Limitations follow directly from this shape:

- Only the `claude` binary is dispatchable — no abstraction point for a
  second runtime.
- The polling loop and the Claude invocation share a process; a Claude
  crash takes the loop down with it (re-restart-on-failure is the
  outer-orchestration container's job).
- Workflow protocol (claim format, branch sync, YAML schema, PR title
  conventions) is encoded *both* in orchestration code *and* in
  `CLAUDE.md` — the runtime "knows" workflow because the LLM does.
- The image carries all toolchains regardless of which task runs; cold
  start and image size are unnecessarily large.

System boundaries:

- **Implementation repo:** `workflow` (single repo for all of this work;
  matches `workspace.yaml -> repos[].id: workflow`).
- **Management repo:** `management-repo` — orchestrator continues to read
  task YAMLs from and write workflow-state mutations to the feature
  branch.
- **External services:** GitHub REST API (PR poll, merge, comment), git
  remotes via SSH key path from `.env`.

---

## 2. Problem framing

Per the approved product spec, the layers must be split so that:

- Orchestration runs as deterministic code with no LLM call (D4).
- Every executor consumes the same container ABI: env vars in,
  `result.json` out (D2).
- All workflow-state writes (task YAML, PR open, dependency unblock,
  log entries, branch sync) are owned by orchestration (D3, D5).
- The repo is restructured into `workflow/runtime/{orchestrator,
  executors/claude, abi}/` (D10).
- The migration is a single-cutover release with no flag and no dual-run
  (D9).

What must remain stable across the cutover:

- The git-SHA claim protocol semantics — the contention model and
  observable outcome are unchanged.
- The task YAML schema, the workspace YAML schema, the management-repo
  branching/PR-merge handoff.
- Operator-facing deploy entry point: `docker compose up`. Its
  *contents* may point at new images; its identity doesn't change.
  K8s CronJob and GH Actions templates are explicitly **out of scope**
  for this feature *and are deleted as part of the cutover* — leaving
  them in place would orphan templates pointing at the removed
  `agent-runtime/` paths, which is messier than removing them. When
  K8s or CI deployment becomes a real need, fresh templates targeting
  the new `runtime/` structure are added in a follow-on feature.

What is fixed by the spec and not relitigated here:

- Container-ABI shape (env vars, `result.json` keys) — D2 froze them.
- Workflow side-effects ownership — D3, D5 froze it on the orchestrator.
- "Same container, no flag" deployment — D1, D9 froze it.

---

## 3. Options considered

The product spec already settled the macro shape. Two real
implementation-level choices remain.

### TD-A. Process boundary inside the container

How does the orchestrator hand a claimed task to the Claude executor on
day 1?

#### Option A1 — In-process function call

Orchestrator imports the Claude executor package; the seam is a TS
function call (`runClaude(input) → result`); `result.json` is a
data structure in memory, not a file.

- Pros: simplest; lowest dev-loop latency; one process, one log stream.
- Cons: shared crash blast radius (a bug in Claude executor takes the
  polling loop down — same as today).
- Cons: doesn't rehearse the file/container ABI on day 1; later
  separation requires writing the file/exec layer for the first time
  in production.

#### Option A2 — Sub-process within the same container

Orchestrator spawns a `node ./executors/claude/dist/index.js` child
process; the seam is the documented ABI — env vars + `result.json` on a
shared filesystem path; orchestrator waits for exit and reads the file.

- Pros: rehearses the real ABI from day 1. The same orchestrator code
  path works unchanged when we later swap the spawn for `docker run`,
  `kubectl create job`, or a queue producer.
- Pros: crash isolation — a Claude executor crash leaves the
  orchestrator alive; the orchestrator marks `blocked` and continues.
- Pros: token / wall-clock budget enforcement is enforceable from
  outside (orchestrator can `kill` the child cleanly).
- Cons: marginal IPC overhead (~ms order, dwarfed by Claude API
  latency).
- Cons: requires writing the result file even on the happy path —
  trivial.

#### Option A3 — Separate container in the same pod from day 1

Two containers (orchestrator + claude-executor) sharing a volume in a
Kubernetes pod (or a docker-compose service pair).

- Pros: closest to the eventual remote-worker model.
- Cons: real operational weight on day 1 — two containers, volume
  plumbing, signaling. Conflicts with D1's "same container default".
- Cons: communication-via-volume is awkward (file watching, no clean
  exit signal).

#### Recommendation: A2 (sub-process)

A2 aligns with D1 ("same container default") *and* D2 (container ABI)
simultaneously. A1 short-circuits the ABI on day 1 — a hidden cost
when we later want to separate. A3 takes on operational weight before
we have evidence we need it.

### TD-B. Repository migration shape

How do we transition source from `workflow/agent-runtime/` to
`workflow/runtime/{orchestrator,executors/claude,abi}/`?

#### Option B1 — Big-bang restructure in one PR

One PR moves all files, defines the ABI seam, extracts the executor,
moves workflow side effects to orchestrator, updates Dockerfile +
docker-compose, deletes the legacy `agent-runtime/` directory.

- Pros: one cutover commit; no temporary duplication; no throwaway
  glue code.
- Pros: matches D9 (single-cutover) at both the source and deployment
  level.
- Cons: large diff. Mitigated because most of it is git renames
  (auto-detected) plus a focused side-effects extraction; the actual
  logic delta is small.

#### Option B2 — Build new shape in parallel; delete legacy at the end

Create `workflow/runtime/` with the new packages; old `agent-runtime/`
keeps working until the final cutover PR replaces deploy entry points.

- Pros: smaller PRs, reviewable in pieces.
- Cons: two source trees temporarily; risk of drift if the legacy is
  modified during the migration.
- Cons: requires writing both source trees correctly during the
  duplication window.

#### Option B3 — Incremental in-place extraction

Step 1: introduce `runtime/abi/` with types + fake executor fixture.
Step 2: introduce `runtime/orchestrator/` by moving polling, claim,
poll, eligibility, bootstrap; orchestrator initially calls the legacy
`run-claude.ts` directly via the new `ExecutorAdapter` seam.
Step 3: introduce `runtime/executors/claude/` by moving `run-claude.ts`
and the briefing-dispatch logic; orchestrator now calls it through the
ABI.
Step 4: move workflow side effects (PR open, YAML mutation, dependency
unblock) from executor to orchestrator.
Step 5: update Dockerfile, image build, docker-compose template.
Step 6: tests + docs.
Step 7: cutover — delete `workflow/agent-runtime/`.

- Pros: each step is independently reviewable; smaller per-PR scope.
- Cons: intermediate steps require throwaway adapter shims (e.g.
  step 2 needs a wrapper so the new orchestrator can call into the
  legacy `run-claude.ts`). That glue is wasted work — written, reviewed,
  and deleted within a few PRs.
- Cons: 7 PRs vs 1 doesn't necessarily reduce review cost when every
  PR is part of the same logical change; reviewers re-load the
  overall shape repeatedly.

#### Recommendation: B1 (big-bang)

For our context the big-bang is the cleaner path:

- **Alpha stage, single developer.** No production users to protect,
  no cross-team review queue to manage.
- **Refactor, not a feature change.** Behavior is identical before and
  after; correctness is verified by the test suite at PR time.
- **No throwaway glue.** B3's intermediate steps each require shim
  adapters that exist only for the duration of the migration. B1
  writes the final shape directly.
- **Reviewable in practice.** The PR is large in line count but
  mostly file moves (git rename detection handles most of the diff).
  The actual logic delta is concentrated in two places: the new ABI
  types, and the side-effects extraction from executor to orchestrator.
- **Matches the user's stated preference for cleanliness over
  intermediate-state safety nets.**

The B1 PR can be reviewed in this order: ABI types → orchestrator
package layout (mostly renames) → Claude executor (mostly the body of
`run-claude.ts` with env-var reading + `result.json` writing) → the
side-effects extraction (the real logic change) → Dockerfile + compose
updates → deletions.

---

## 4. Chosen design

### 4.1 Package layout

```
workflow/runtime/
  abi/
    src/
      types.ts             # ExecutorInput, ExecutorResult, terminal_status enum
      schema.ts            # JSON Schema for result.json (runtime-validated)
      fake-executor.ts     # no-op executor used by orchestrator tests
    docs/
      abi-spec.md          # human-readable contract; the source of truth
                           # for third-party runtime authors
    package.json
  orchestrator/
    src/
      main.ts              # polling loop entry
      bootstrap/           # workspace clone/pull, env resolution
      eligibility/         # ready-task filter
      claim/               # git-SHA claim protocol
      poll/                # workspace pulls, PR-merge poll, conflict handler
      briefing/            # briefing markdown generator (moved from
                           #   agent-runtime/src/bootstrap/agent-context.ts)
      side-effects/        # task YAML writers, PR open, dep unblock,
                           #   branch sync, log appenders (moved from
                           #   inside-Claude responsibilities)
      adapter/
        adapter.ts         # ExecutorAdapter interface; default in-container
                           #   sub-process spawner
        spawn.ts           # child_process wrapper that implements the ABI
                           #   on the orchestrator side
    Dockerfile             # tiny: Node + git + GH token; no toolchains
    package.json
  executors/
    claude/
      src/
        index.ts           # entry: read env, read briefing, run claude -p,
                           #   parse stdout, write result.json
        token-usage.ts     # parse claude --json output for usage
      Dockerfile           # Node + Claude Code CLI + task toolchains
      package.json
```

The legacy `workflow/agent-runtime/` directory is deleted as part of T2
(the same PR that introduces `workflow/runtime/`).

### 4.2 The ABI in concrete terms

**Inputs the orchestrator passes** (env vars + small mounted files):

```ts
// runtime/abi/src/types.ts
export interface ExecutorInput {
  taskId: string;
  featureId: string;
  workspaceId: string;
  taskRepoUrl: string;        // git URL of the implementation repo (SSH or HTTPS)
  taskRepoBranch: string;     // feature branch to check out and push to
  taskRepoPath: string;       // working-directory path; executor materializes
                              //   the repo here (clone if absent, fetch + checkout
                              //   + pull if present and origin matches)
  briefingPath: string;       // markdown file with task description, quality bar
  resultPath: string;         // path the executor must write result.json to
  budgetTokens?: number;      // optional; absent for non-LLM executors
  sshKeyPath: string;
  githubToken: string;
}
```

The sub-process spawner serializes these into env vars
(`TASK_ID`, `FEATURE_ID`, `WORKSPACE_ID`, `TASK_REPO_URL`,
`TASK_REPO_BRANCH`, `TASK_REPO_PATH`, `BRIEFING_PATH`, `RESULT_PATH`,
`BUDGET_TOKENS`, `SSH_KEY_PATH`, `GITHUB_TOKEN`); the executor's
entrypoint reads them back via `process.env`.

**Why URL + branch + path, not just a path.** The orchestrator and
the executor may run in different filesystems (separate K8s pods, a
remote worker pool, a queued job). A path passed by the orchestrator
has no meaning across that boundary. Passing `TASK_REPO_URL` +
`TASK_REPO_BRANCH` makes the ABI topology-agnostic — the executor
materializes the repo wherever it runs. `TASK_REPO_PATH` remains in
the ABI as the orchestrator-dictated working-directory location, but
the **executor**, not the orchestrator, is the authoritative actor
responsible for ensuring the working tree is in the correct state.

**Why no `MGMT_REPO_*`.** Per D5, the executor never reads or writes
the management repo (task YAML mutations, PR open, log entries, and
dependency unblock are all orchestrator responsibilities). The ABI
omits any management-repo input intentionally — passing it would
imply responsibilities the executor must not have.

**Materialization protocol on the executor side.** The executor's
entrypoint runs the following sequence at startup, before any task
work:

```
if TASK_REPO_PATH exists and is a git repo:
    git -C TASK_REPO_PATH remote get-url origin
    if origin does not match TASK_REPO_URL:
        exit non-zero with result.json {
          terminal_status: "failed",
          blocked_reason: "task_repo_origin_mismatch"
        }
    git -C TASK_REPO_PATH fetch origin
    git -C TASK_REPO_PATH checkout TASK_REPO_BRANCH
    git -C TASK_REPO_PATH pull --ff-only origin TASK_REPO_BRANCH
else:
    git clone TASK_REPO_URL TASK_REPO_PATH
    git -C TASK_REPO_PATH checkout TASK_REPO_BRANCH
```

In shared-filesystem topologies the orchestrator may pre-populate
`TASK_REPO_PATH` (warming the cache), in which case the executor's
materialization collapses to a fast `git fetch + checkout + pull`.
In separated topologies the orchestrator does nothing to the path
and the executor performs a full clone. The contract is identical
in both cases.

**Outputs the executor must produce:**

```ts
// runtime/abi/src/types.ts
export type TerminalStatus = "in_review" | "blocked" | "failed";

export interface ExecutorResult {
  terminal_status: TerminalStatus;
  token_usage?: { input: number; output: number };
  blocked_reason?: string;       // required iff terminal_status === "blocked"
  blocked_suggestion?: string;   // required iff terminal_status === "blocked"
}
```

Validated against `runtime/abi/src/schema.ts` (JSON Schema) on read.
Schema violations are treated as `terminal_status: failed,
blocked_reason: "result_schema_invalid"`.

**Side effects the executor performs:**

- Materialize `taskRepoPath` from `taskRepoUrl` on `taskRepoBranch`
  per the protocol above.
- Make code changes inside `taskRepoPath`.
- `git commit && git push origin <taskRepoBranch>` from `taskRepoPath`.
- Write `result.json` at `resultPath`.
- Exit 0 on completion; non-zero on crash or materialization failure.

**Side effects the executor never performs:**

- Reading or writing the management repo (no `MGMT_REPO_*` in the ABI).
- Writing task YAML files.
- Opening pull requests.
- Applying dependency unblock.
- Anything in `CLAUDE.md` related to workflow protocol.

### 4.3 Lifecycle flow (one tick of the polling loop)

```
1. orchestrator/main.ts: pull every watched workspace
2. orchestrator/eligibility: scan task YAMLs; produce candidate list
3. orchestrator/claim: for each candidate, attempt git-SHA claim
       on success: workspace branch is pushed with status: in_progress
4. orchestrator/briefing: generate briefing markdown to
       <tmp>/<task_id>/briefing.md
5. orchestrator/adapter: call ExecutorAdapter.run(input)
       default impl spawns child:
         env: ABI variables (TASK_REPO_URL, TASK_REPO_BRANCH,
              TASK_REPO_PATH, BRIEFING_PATH, RESULT_PATH, ...)
         cwd: <tmp>/<task_id>
       executor's first action: materialize TASK_REPO_PATH from
         TASK_REPO_URL on TASK_REPO_BRANCH (clone or fetch+checkout+pull
         per §4.2 materialization protocol). The orchestrator may
         pre-populate the path as an optimization in shared-filesystem
         topologies; the executor's materialization step is correct in
         either case.
   wait for child exit
6. orchestrator/side-effects:
       read result.json
       if result.pr_url is present:
         record result.pr_url in task YAML pr field
       if terminal_status === "in_review":
         write task YAML status: in_review, append log entry
       if terminal_status === "blocked":
         write task YAML status: blocked,
           blocked_reason / blocked_suggestion,
           append log entry
       if terminal_status === "failed" or schema invalid:
         write task YAML status: blocked,
           blocked_reason: "executor_failed:<reason>",
           append log entry

   NOTE: orchestrator does NOT open the implementation PR — the
   executor opens it before writing result.json, regardless of
   terminal_status (see revised D5). Orchestrator only opens the
   management/workspace PR (at claim time, step 3 above). Both PRs
   exist independently of implementation outcome — neither is gated
   on the executor's quality gate. pr_url is recorded whenever it is
   present in result.json; terminal_status is translated to task YAML
   state as a separate concern.
7. orchestrator/poll: continue checking PR-merge state for
   previously-in_review tasks (this part is unchanged from today)
```

### 4.4 ExecutorAdapter interface

```ts
// runtime/orchestrator/src/adapter/adapter.ts
import type { ExecutorInput, ExecutorResult } from "@runtime/abi";

export interface ExecutorAdapter {
  run(input: ExecutorInput): Promise<ExecutorResult>;
}
```

Default implementation is `SubProcessAdapter` (TD-A2): spawns a child
process inside the same container. Future implementations can be
`DockerRunAdapter`, `K8sJobAdapter`, `QueueProducerAdapter` — none
require orchestrator code changes; they only require swapping the
adapter wired in `runtime/orchestrator/src/main.ts`.

The `runtime/abi/src/fake-executor.ts` fixture is a `FakeAdapter`: it
satisfies `ExecutorAdapter` directly, returns a configurable
`ExecutorResult` synchronously, and never spawns anything. Used by
orchestrator tests.

#### Future composition with `agent-runtime-selector`

The selector feature, when resumed, composes with this adapter design
without changing the `ExecutorAdapter` interface. It adds two things
on top of what this feature ships:

1. **A runtime registry** — config-driven map from
   `task.execution.runtime` (e.g. `claude-code`, `hermes`) to a binary
   path or image ref. Lives in orchestrator config, not in the adapter.
2. **A second executor package** — `runtime/executors/hermes/`, sibling
   of `claude/`, implementing the same ABI.

The orchestrator's dispatch logic gains one step: read
`task.execution.runtime`, resolve via the registry, pass the resolved
binary or image ref to the adapter. Tasks with no runtime field
default to `claude-code`.

How this lands depends on deployment topology:

- **Single-container deployment** (day-1 default for this feature):
  the container ships with multiple executor binaries pre-baked
  (`./executors/claude/dist/index.js`,
  `./executors/hermes/dist/index.js`). `SubProcessAdapter` spawns
  whichever binary the registry resolves. Adding Hermes here means
  adding a binary to the image and a registry entry.
- **Multi-container deployment** (later): each runtime is its own
  image. `DockerRunAdapter` (or `K8sJobAdapter`) takes the resolved
  image ref from the registry. Adding Hermes here means publishing a
  Hermes image and registering it.

In both cases, the runtime author never sees the adapter — they only
see the ABI. No orchestrator-core changes, no adapter changes, no ABI
changes are required to introduce a new runtime. This is the property
the split is designed to give us; the selector feature is its first
real consumer.

### 4.5 What lives where after the move

| Today | After split |
|---|---|
| `agent-runtime/src/main.ts` (loop + dispatch) | `runtime/orchestrator/src/main.ts` |
| `agent-runtime/src/bootstrap/bootstrap.ts` | `runtime/orchestrator/src/bootstrap/` |
| `agent-runtime/src/bootstrap/agent-context.ts` | `runtime/orchestrator/src/briefing/` |
| `agent-runtime/src/eligibility/match.ts` | `runtime/orchestrator/src/eligibility/match.ts` |
| `agent-runtime/src/claim/claim-task.ts` | `runtime/orchestrator/src/claim/claim-task.ts` |
| `agent-runtime/src/poll/*` | `runtime/orchestrator/src/poll/*` |
| `agent-runtime/src/loop/run-claude.ts` | `runtime/executors/claude/src/index.ts` (entrypoint) + `token-usage.ts` |
| Inline-in-Claude: task YAML mutations, dep unblock | `runtime/orchestrator/src/side-effects/` (NOT `pr-create`; impl PR open stays with executor per revised D5) |
| `agent-runtime/Dockerfile` (everything bundled) | Two Dockerfiles: orchestrator (lean) + claude (toolchains) |
| `agent-runtime/templates/docker-compose.*` | `runtime/orchestrator/templates/docker-compose.*` (point at the orchestrator image, which spawns the executor binary inside the same container). K8s and GH Actions templates from `agent-runtime/templates/` are **deleted** as part of the cutover — leaving stale templates pointing at the removed `agent-runtime/` paths is anti-clean. Fresh templates targeting `runtime/` are added in a follow-on feature when K8s or CI deployment is actually needed. |

### 4.6 CLAUDE.md / briefing changes

Today's `CLAUDE.md` is read by Claude as system context for every task.
After the split, it splits into:

- **Orchestration spec** — workflow rules read by orchestrator code:
  task-status transitions, branch sync protocol, claim format, PR title
  format, dependency unblock, write-only-your-own-task-YAML, branch-
  merge rule, no-direct-push-to-main rule. These remain in `CLAUDE.md`
  for human readers but stop being injected as runtime-side context for
  the executor.
- **Briefing template** — produced by `orchestrator/src/briefing/` and
  written to `briefingPath`. Contains: task description (from
  `tasks.md`), quality bar, model policy, RAG-injected project context.
  Does **not** contain workflow rules.

The Claude executor's package effectively becomes "given this briefing,
modify code, commit, push, run tests, open the impl PR, write
result.json." Any workflow knowledge inside Claude is removed; the
`pr-create` skill remains in Claude's loaded skills (it is the impl-PR
opener) but skills that mutate task YAML or open the workspace PR are
not loaded into Claude's context.

Migration of the existing `CLAUDE.md` content is part of T4 (docs).

### 4.6.1 PR ownership split (revised D5)

Per the revised D5 in `product-spec.md`, "PR open" is split across two
PRs with different owners:

| PR | Repo | Owner | When opened | Title format |
|---|---|---|---|---|
| Implementation PR | impl repo (e.g. `agent-workflow`) | **Executor** | After tests run, before `result.json` is written | `feat(<featureId>/<taskId>): <task description>` |
| Workspace PR | management repo | **Orchestrator** | At claim time | `feat(<featureId>/<taskId>): <task title>` |

**Why this split.** The executor has the diff, the test output, and the
implementation context to write a meaningful PR body. The orchestrator
has the workflow-state context (task YAML state, log entries, dependency
graph) to manage the workspace PR. Forcing both onto a single owner
loses the context one of them has.

**ABI implications.** `result.json` schema gains one field:

| Field | Required when | Meaning |
|---|---|---|
| `pr_url` | An impl PR was opened | URL of the impl PR the executor opened. Reported regardless of `terminal_status` (a `blocked` task with a draft PR still carries `pr_url`). Orchestrator records it in `task.pr.url`. |

**No `tests_passed` field is added.** Per D4, the orchestrator is pure
workflow-state code — it does not gate on implementation-level signals
like test outcomes. The executor's internal quality gate (tests, lint,
type-check) is the executor's private concern. Gate failure means the
executor reports `terminal_status: "blocked"` with an appropriate
`blocked_reason` (e.g. `tests_failed`); the orchestrator only sees the
translation and never inspects what the gate did.

**PR opening is not gated on quality.** Both the workspace PR (opened
by the orchestrator at claim time) and the impl PR (opened by the
executor) are part of the task lifecycle, not artifacts of "did the
work succeed". The impl PR is opened whenever there are commits to PR
— if the work passed the executor's gate, the PR is opened ready for
review; if the work was blocked, the PR is opened as a draft (or
left open with a comment summarising the failure) so the failed
attempt is documented and can be picked up later. In both cases
`pr_url` is reported.

**Code-level implications.**

- `runtime/orchestrator/src/side-effects/open-pr.ts` (the orchestrator's
  `openImplPr`) is **deleted**. The executor is the sole impl-PR opener.
- `runtime/orchestrator/src/side-effects/dispatch.ts` no longer calls
  `openImplPr`. It reads `result.pr_url` whenever it is present (any
  terminal_status) and writes it to the task YAML's `pr.url` field.
  No new gating logic — `terminal_status` translation is unchanged.
- The Claude executor's `runtime/executors/claude/src/index.ts` is
  responsible for ensuring Claude opens the impl PR (via the
  `pr-create` skill) before writing `result.json`, regardless of test
  outcome. The executor extracts the PR URL from Claude's output and
  writes it to `result.json.pr_url` whenever a PR was opened. If
  Claude's test plan reports failures, the executor still records
  `pr_url`; only `terminal_status` flips to `"blocked"` with
  `blocked_reason: "tests_failed"`.

### 4.7 Operational implications

- Two Docker images replace one. The orchestrator image is small
  (~Node + git + GH token); the Claude executor image carries the
  toolchains.
- On day 1 the deployment can still ship one image with both binaries
  if operators want to keep image-count low; the orchestrator's adapter
  spawns the local Claude executor binary instead of pulling a separate
  image. The choice is per-deployment, not per-architecture.
- Token-budget enforcement: orchestrator validates `BUDGET_TOKENS`
  pre-dispatch; executor reports actual usage post-hoc (D8).
- Wall-clock timeout: orchestrator owns it. Sub-process is killed via
  `process.kill(SIGTERM)` after timeout; no `result.json` produced →
  orchestrator marks `blocked` (D7).
- Crash isolation: an executor crash exits non-zero with no `result.json`
  → orchestrator marks `blocked: executor_crashed`. Polling loop
  continues. (Today, an unhandled error in `run-claude.ts` would
  propagate up and the container restarts.)

---

## 5. Dependency analysis

### Internal dependencies

- **Workflow features**: none. `agent-runtime-selector` was previously
  listed; per spec correction it is downstream of this feature, not
  upstream. This feature is the **last** of the agent-runtime-* series
  before runtime work shifts to selector and Hermes.
- **Existing tests**: orchestrator tests (eligibility match, claim
  protocol, poll handlers) must move with the source. They are
  currently structured as unit tests against the orchestration code,
  which makes the move mechanical. No test rewrite is expected at
  package-extraction time; only seam tests are new.
- **`CLAUDE.md`**: must be edited as part of T4 to remove runtime-
  injected workflow rules and to point at the briefing-template
  location.

### External dependencies

- **GitHub REST API**: unchanged. Orchestrator continues to poll PR
  state, open PRs, and merge workspace PRs.
- **SSH key + GH token**: unchanged. Both passed to executor via the
  ABI; orchestrator continues to use them for management-repo writes.
- **Node.js runtime**: unchanged. Both packages are Node/TypeScript.
- **Claude Code CLI**: unchanged. Continues to be invoked via
  `claude -p` from the executor entrypoint.

### Configuration dependencies

- **`.env`**: no new variables required for day 1. Future executor
  images may want a `RUNTIME_REGISTRY` config (image refs per runtime
  name); explicitly out of scope for this feature.
- **`agent.yaml`**: unchanged.
- **`workspace.yaml`**: unchanged. (`management_repo` and `repos[]`
  identifiers continue as-is.)

### Release dependencies

- The cutover (T2) ships in a single workflow-repo PR that introduces
  `workflow/runtime/`, deletes `workflow/agent-runtime/`, updates
  docker-compose, and bumps the image tag. Operators pulling `:latest`
  get the new shape; nothing is preserved from the old shape.
- No coordination with `digital-factory-ui`, `rag-service`, or
  `management-repo` is required — none of them depend on runtime
  internals.

### Unresolved dependencies

None. All blocking decisions are fixed in the product spec.

---

## 6. Parallelization / blocking analysis

The split has five planned tasks (T1–T5). Per-task formal YAMLs and
narratives are produced in Phase 2 of this skill, after design approval;
the dependency structure below is the input to that phase.

```
T1: Define ABI — types, JSON schema, fake-executor fixture, abi-spec.md
    skeleton; one self-contained PR adding `workflow/runtime/abi/`.
  └── Can begin now — no blockers
  │
  T2: Big-bang split — extract orchestrator, extract Claude executor,
      move workflow side effects (PR open, task YAML mutation,
      dependency unblock, log entries) from executor to orchestrator,
      update Dockerfile + docker-compose, delete legacy
      `workflow/agent-runtime/`. One PR, the cutover PR.
      Final subtask of T2: walk the migrated `runtime/orchestrator/`
      package with fresh eyes and populate the concrete refactor
      checklist on T5 (the post-split code quality task). T5's scope
      cannot be enumerated until the split lands and the orchestrator
      package boundary is visible — T2's last act is to fill it in.
        └── BLOCKED on T1 (ExecutorInput / ExecutorResult types must
            be importable; FakeAdapter contract must be defined so
            the new orchestrator can be wired against it)
      │
      T3: Test migration + seam tests against the fake executor —
          orchestrator-side e2e against FakeAdapter, Claude executor
          smoke test driving the entrypoint with a fixture briefing.
            └── BLOCKED on T1 (FakeAdapter must exist for seam tests)
            └── BLOCKED on T2 (the new package layout must exist before
                tests can target it)
      │
      T4: Documentation update — flesh out abi-spec.md, split CLAUDE.md
          (workflow rules stay in CLAUDE.md; runtime-injected guidance
          moves to the briefing template), update operator guide for
          docker-compose, write handoff doc.
            └── BLOCKED on T1 (ABI spec doc lives in `runtime/abi/docs/`
                and references the types from T1)
            └── BLOCKED on T2 (CLAUDE.md split + operator guide reflect
                the new package layout)
      │
      T5: Orchestrator code quality pass — refactor `runtime/orchestrator/`
          against the checklist populated by T2's final subtask. Scope
          is bounded to cleanups *exposed* by the split (dead code paths
          that only existed to bridge orchestration and execution;
          redundant re-exports; function granularity that no longer
          fits; import simplifications enabled by the new structure).
          Out of scope: library swaps, async/await rewrites, test
          framework changes, type system overhauls. T5 produces its own
          PR; it does not gate the cutover.
            └── BLOCKED on T2 (the new package layout must exist; T2's
                final subtask must have populated T5's concrete
                checklist before T5 can begin)
            └── T3, T4, and T5 run in parallel after T2
      │
      T6: PR ownership split (revised D5) — formalize the executor as
          impl-PR opener, orchestrator as workspace-PR + workflow-state
          owner. Add `pr_url` to `result.json` schema (no
          `tests_passed` — orchestrator does not gate on test outcomes
          per D4); remove `runtime/orchestrator/src/side-effects/open-pr.ts`;
          update `dispatch.ts` to read `pr_url` from `result.json` and
          record it in the task YAML; update Claude executor entrypoint
          to extract PR URL from Claude's output and to report
          `terminal_status: "blocked"` with `blocked_reason: "tests_failed"`
          when its internal test gate fails; update
          `runtime/abi/docs/abi-spec.md`. Added 2026-05-02 after the
          original five-task plan revealed that orchestrator-opened
          impl PRs lose context the executor already has.
            └── BLOCKED on T2 (side-effects/open-pr.ts must exist to
                be removed; dispatch.ts must exist to be updated)
```

Read-out of waves:

- **Wave 1 (immediately after design approval):** T1 alone.
- **Wave 2 (after T1 lands):** T2 alone — the cutover PR. T2's last
  subtask seeds T5's scope.
- **Wave 3 (after T2 lands):** T3, T4, T5 in parallel.
- **Wave 4 (after T2 lands; added 2026-05-02):** T6 — revised D5
  formalization. Independent of T3/T4/T5 but added after them in
  practice because it was identified during T4's handoff drafting.

No tasks block on external decisions or on other features. The work is
self-contained within the `workflow` repo.

Note on T2 reviewability: the diff is large in line count but
concentrated in three logical chunks — (a) new orchestrator package
layout (mostly file renames + import-path updates, auto-detected by
git), (b) new Claude executor package (mostly the body of the existing
`run-claude.ts` with env-var reading + `result.json` writing), (c) the
side-effects extraction (the real logic delta — what moves from
executor responsibility to orchestrator responsibility). Reviewing in
that order keeps the conceptual cost manageable. Crucially, T2 does
**not** include orchestrator-internal refactors — those are deferred
to T5 to keep T2's PR mechanical and reviewable.

---

## 7. Repository impact

| Repo | Why touched |
|---|---|
| `workflow` | Every task in this feature lands here. Source restructure (`agent-runtime/` → `runtime/{orchestrator,executors/claude,abi}/`), Dockerfile changes, deploy template updates, test migration, docs update, legacy deletion. |
| `management-repo` | Not touched. The CLAUDE.md change in T4 lives in `workflow` (the canonical CLAUDE.shared.md is in the workflow root; per workspace rules `sync-workspace-rules` propagates it back into management-repo's `CLAUDE.md` as a separate operator action). |
| `digital-factory-ui` | Not touched. Has no runtime dependency. |
| `rag-service` | Not touched. Has no runtime dependency. |

`repo: workflow` for every task. One-repo enforcement holds: each
task's subtasks reference paths only inside `workflow/`.

---

## 8. Validation and release impact

### Testing expectations

- **Unit tests** for orchestrator side-effects (PR open, YAML write,
  dependency unblock, log appender) — new tests written as part of T2.
  Use in-memory fakes for the management repo file system.
- **Seam tests** for the orchestrator + ExecutorAdapter against
  `FakeAdapter` — written in T3. Cover: `in_review` happy path,
  `blocked` with reason, `failed` with non-zero exit, schema-invalid
  result, wall-clock timeout.
- **Smoke test** of the Claude executor — keeps today's coverage; the
  test calls the executor entrypoint directly with a fixture briefing
  and asserts the result file shape. Written in T3.
- **End-to-end smoke** before merging T2: one real task driven through
  the new shape on a non-production workspace, verifying claim → PR
  open → merge handoff. This smoke is a gate on T2's PR, not its own
  task.

### Migration / config impact

- No `.env` changes day 1.
- `agent.yaml` schema unchanged.
- Image tags bump in T2 (operators using docker-compose pulling
  `:latest` get the new orchestrator image and the new claude
  executor image).
- K8s and GH Actions deploy templates are **deleted** in T2 alongside
  the legacy `agent-runtime/` directory. Re-introducing them is a
  follow-on feature, designed against the new `runtime/` structure
  from scratch.

### Rollout concerns

- Single-cutover (D9) — no flag, no dual-run. The risk concentration is
  in T3 (seam tests against the fake executor) and the end-to-end
  smoke gate on T2. Both are explicitly called out as gates.
- T5 (orchestrator quality refactor) does **not** gate the cutover.
  The cutover ships when T2 + T3 + T4 land; T5 follows as
  improvement-on-top. Treating T5 as non-blocking keeps the cutover
  decoupled from refactor judgment calls.
- Operators must be told that `workflow/agent-runtime/` is gone after
  cutover; the docs update in T4 covers this.
- Local docker-compose is the only deploy path validated as part of
  this feature. K8s CronJob and GH Actions templates are deleted in
  T2, not silently left pointing at removed paths. Operators relying
  on those paths must wait for a follow-on feature that designs them
  fresh against `runtime/`.

### Backward compatibility

Per N1 and the alpha-stage decision in D9, backward compatibility is
not a constraint. Task YAMLs from before cutover continue to work
unchanged because the YAML schema is untouched. Workspace YAML and
management-repo branch conventions are untouched.

### Deployment / handoff implications

- The handoff doc (`handoffs/agent-runtime-split.md`) is written as
  part of T4 and records the final state: new package layout, new
  image refs, deleted paths.
- Future runtime work (selector, Hermes) starts from the ABI spec
  doc produced in T1 and fleshed out in T4. That doc is the contract
  third-party runtime authors pin against.
