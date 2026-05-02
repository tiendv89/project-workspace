# Task Breakdown — agent-runtime-split

Feature status: `in_tdd` | Tasks stage: `draft` | Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Define runtime ABI — types, schema, fake-executor fixture | — |
| T2 | 2 | Big-bang split — extract orchestrator + Claude executor, cutover | T1 |
| T3 | 3 | Test migration + seam tests against fake executor | T1, T2 |
| T4 | 3 | Documentation update — flesh out abi-spec.md, split CLAUDE.md, handoff | T1, T2 |
| T5 | 3 | Orchestrator code quality pass | T2 |
| T6 | 4 | PR ownership split (revised D5) — executor opens impl PR; orchestrator records pr_url | T2 |

---

## T1 — Define runtime ABI — types, schema, fake-executor fixture

### Description

Establish `workflow/runtime/abi/` as a self-contained package that
defines the contract every executor must satisfy. T1 produces no
behavior change to the live runtime; it adds a new package alongside
the legacy `workflow/agent-runtime/` and exposes the types that T2
will wire against.

Three artifacts ship in this task:

1. **`runtime/abi/src/types.ts`** — TypeScript surfaces:
   - `ExecutorInput` — the structured input the orchestrator passes to
     an executor. Fields per technical-design §4.2: `taskId`,
     `featureId`, `workspaceId`, `taskRepoUrl`, `taskRepoBranch`,
     `taskRepoPath`, `briefingPath`, `resultPath`, `budgetTokens?`,
     `sshKeyPath`, `githubToken`. Note: no `mgmtRepoPath` — the
     executor never reads or writes the management repo (per D5).
     The executor is responsible for materializing the repo at
     `taskRepoPath` from `taskRepoUrl` on `taskRepoBranch` (clone if
     absent, fetch + checkout + pull if present and origin matches).
   - `ExecutorResult` — the structured output the executor produces
     via `result.json`. Fields: `terminal_status`
     (`"in_review" | "blocked" | "failed"`), `token_usage?`,
     `blocked_reason?` (required when `terminal_status === "blocked"`),
     `blocked_suggestion?` (required when `terminal_status === "blocked"`).
   - `ExecutorAdapter` — the orchestrator-side seam:
     `run(input: ExecutorInput): Promise<ExecutorResult>`.

2. **`runtime/abi/src/schema.ts`** — JSON Schema for `result.json`,
   used by orchestrator to validate executor output on read. Schema
   violations are mapped to `terminal_status: "failed",
   blocked_reason: "result_schema_invalid"`.

3. **`runtime/abi/src/fake-executor.ts`** — `FakeAdapter`
   implementation of `ExecutorAdapter`. Returns a configurable
   `ExecutorResult` synchronously; never spawns anything; used by
   orchestrator tests in T3.

4. **`runtime/abi/docs/abi-spec.md`** — skeleton spec document for
   third-party runtime authors. Skeleton only — full content lands in
   T4. T1 ships the structure and links to the type definitions.

This is the foundation. Wave 1, no upstream blockers.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Create `workflow/runtime/abi/` directory with `package.json` and `tsconfig.json`
- [ ] Define `ExecutorInput`, `ExecutorResult`, `TerminalStatus`, `ExecutorAdapter` in `src/types.ts`
- [ ] Define JSON Schema for `result.json` in `src/schema.ts`; export a validator function
- [ ] Implement `FakeAdapter` in `src/fake-executor.ts`: factory takes a configurable result, returns an adapter; no I/O
- [ ] Create `docs/abi-spec.md` skeleton with section headings (Inputs, Outputs, Side effects executor performs, Side effects executor never performs, Lifecycle); leave full content for T4
- [ ] Add unit tests for the JSON Schema validator: valid in_review, valid blocked with reason+suggestion, invalid (missing reason on blocked), invalid (unknown terminal_status)
- [ ] Verify the package builds in isolation (`yarn build` or equivalent inside `runtime/abi/`)
- [ ] Verify nothing imports from `runtime/abi/` yet — this package is intentionally orphaned at end of T1

---

## T2 — Big-bang split — extract orchestrator + Claude executor, cutover

### Description

The cutover PR. Per technical-design §4 and §6, T2 is one PR that:

- Creates `workflow/runtime/orchestrator/` and moves the polling loop,
  claim, poll, eligibility, bootstrap, and briefing-generation code
  into it. Most of the diff is git-detected file renames + import-path
  updates.
- Creates `workflow/runtime/executors/claude/` and moves the body of
  `agent-runtime/src/loop/run-claude.ts` into it as the ABI-conformant
  entrypoint: reads env vars per `ExecutorInput`, runs `claude -p`,
  writes `result.json` per `ExecutorResult`, exits 0/non-zero.
- Implements `SubProcessAdapter` (TD-A2) in
  `runtime/orchestrator/src/adapter/spawn.ts`: spawns the Claude
  executor binary as a child process inside the same container,
  serializes `ExecutorInput` into env vars, waits for exit, reads and
  validates `result.json`.
- **Moves workflow side effects** from inside-Claude responsibility to
  orchestrator code (`runtime/orchestrator/src/side-effects/`):
  PR open, task YAML mutation (`in_progress → in_review/blocked`),
  dependency unblock (auto-ready rule), log entries, branch sync.
  Today these are partly performed by Claude via `pr-create` skill +
  CLAUDE.md guidance; after T2 they are deterministic orchestrator
  code triggered by reading `result.json`.
- Updates the briefing-generation logic so the briefing markdown
  carries task-specific context only — workflow rules stop being
  injected into Claude's runtime context.
- Replaces the single bundled Dockerfile with two Dockerfiles:
  `runtime/orchestrator/Dockerfile` (lean — Node + git + GH token) and
  `runtime/executors/claude/Dockerfile` (Node + Claude CLI + task
  toolchains). On day 1 the deployed image can still bake both
  binaries together; the choice is per-deployment.
- Updates `docker-compose` template to point at new images.
- **Deletes** `workflow/agent-runtime/` entirely, including K8s
  CronJob and GH Actions templates (they would otherwise orphan
  pointing at removed paths — re-introduction is a follow-on
  feature).

T2 includes a final subtask: walk the migrated `runtime/orchestrator/`
package with fresh eyes and populate the concrete refactor checklist
under T5's `### Subtasks` section. T5's scope cannot be enumerated
until the split lands; T2's last act is to enumerate it.

T2 does **not** include orchestrator-internal refactors — those defer
to T5. T2 also does not include test rewrites — those defer to T3
(though existing tests must be migrated to the new layout and
continue to pass).

End-to-end smoke gate: before merging T2's PR, drive one real task
through the new shape on a non-production workspace and verify
claim → PR open → merge handoff.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Create `workflow/runtime/orchestrator/` package skeleton (`package.json`, `tsconfig.json`, `Dockerfile`)
- [ ] Create `workflow/runtime/executors/claude/` package skeleton (`package.json`, `tsconfig.json`, `Dockerfile`)
- [ ] Move polling loop, claim, poll, eligibility, bootstrap from `agent-runtime/src/` to `runtime/orchestrator/src/` with import paths updated
- [ ] Move `agent-runtime/src/bootstrap/agent-context.ts` to `runtime/orchestrator/src/briefing/` and rename to reflect briefing semantics
- [ ] Move `agent-runtime/src/loop/run-claude.ts` body into `runtime/executors/claude/src/index.ts` as the ABI-conformant entrypoint
- [ ] Implement `SubProcessAdapter` in `runtime/orchestrator/src/adapter/spawn.ts`: env-var serialization, child spawn, wait, validate result.json
- [ ] Wire `runtime/orchestrator/src/main.ts` to instantiate `SubProcessAdapter` and call it from the dispatch step
- [ ] Move PR open from `pr-create` skill invocation to `runtime/orchestrator/src/side-effects/open-pr.ts` (orchestrator-side)
- [ ] Move task YAML mutation (in_progress → in_review/blocked) from inside-Claude flow to `runtime/orchestrator/src/side-effects/mutate-task-yaml.ts`
- [ ] Move dependency unblock (auto-ready rule) to `runtime/orchestrator/src/side-effects/unblock-deps.ts`
- [ ] Move log-entry appending to `runtime/orchestrator/src/side-effects/append-log.ts`
- [ ] Update briefing template: remove runtime-injected workflow rules; carry task description, quality bar, model policy, RAG context only
- [ ] Migrate existing tests to compile against new package layout (no logic changes — that is T3's scope)
- [ ] Update `docker-compose` template to reference the new orchestrator image (and bundled Claude binary on day 1)
- [ ] Delete `workflow/agent-runtime/` directory entirely (source, Dockerfile, all `templates/*` including K8s CronJob and GH Actions)
- [ ] End-to-end smoke gate: drive one real task through the new shape on a non-production workspace; verify claim → PR open → merge handoff before merging this PR
- [ ] **(Final)** Walk migrated `runtime/orchestrator/` with fresh eyes; populate concrete refactor checklist under T5's `### Subtasks` section in `tasks.md`

---

## T3 — Test migration + seam tests against fake executor

### Description

After T2 lands, the new package layout exists but is exercised only by
the migrated unit tests carried over from `agent-runtime/`. T3 adds
the test coverage that the split was meant to enable: orchestrator-
side end-to-end against `FakeAdapter`, exercising the ABI seam without
ever invoking Claude.

Three test layers:

1. **Orchestrator side-effects unit tests** — exercise `open-pr.ts`,
   `mutate-task-yaml.ts`, `unblock-deps.ts`, `append-log.ts` in
   isolation. Use in-memory fakes for the management-repo file system
   and a recorded GitHub API response for PR open.

2. **Seam tests against `FakeAdapter`** — drive
   `runtime/orchestrator/src/main.ts` (or a test entrypoint that uses
   the same dispatch) with `FakeAdapter` injected. Cover:
   - `in_review` happy path → orchestrator opens PR, mutates YAML,
     appends log, applies dep unblock if applicable
   - `blocked` with reason + suggestion → orchestrator marks blocked,
     records reason/suggestion
   - `failed` (executor non-zero exit, no result.json) → orchestrator
     marks blocked with `executor_crashed`
   - schema-invalid `result.json` → orchestrator marks failed with
     `result_schema_invalid`
   - wall-clock timeout → orchestrator kills child, marks blocked
     with `executor_timeout`

3. **Claude executor smoke test** — drive
   `runtime/executors/claude/src/index.ts` directly with a fixture
   briefing and assert the `result.json` shape and exit code. Does
   not invoke a real LLM; uses Claude CLI's dry-run / fixture mode if
   available, or a stub `claude` binary on `PATH` for the test.

T3 runs in parallel with T4 and T5 after T2 lands.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Add unit tests for `open-pr.ts` against in-memory + recorded GitHub fixtures
- [ ] Add unit tests for `mutate-task-yaml.ts` covering all terminal_status cases
- [ ] Add unit tests for `unblock-deps.ts` covering: no unblock, single unblock, multiple unblocks, partial dep satisfaction
- [ ] Add unit tests for `append-log.ts` covering action enum + timestamp + actor fields
- [ ] Add seam test: in_review happy path with `FakeAdapter`
- [ ] Add seam test: blocked with reason + suggestion
- [ ] Add seam test: executor non-zero exit (no result.json) → `executor_crashed`
- [ ] Add seam test: schema-invalid result.json → `result_schema_invalid`
- [ ] Add seam test: wall-clock timeout → `executor_timeout`
- [ ] Add Claude executor smoke test driving the entrypoint with a fixture briefing
- [ ] Verify all tests pass on the new package layout

---

## T4 — Documentation update — flesh out abi-spec.md, split CLAUDE.md, handoff

### Description

Documentation closes out the cutover for human readers and future
runtime authors.

Four documents land in this task:

1. **`runtime/abi/docs/abi-spec.md`** — flesh out the skeleton from
   T1. The spec doc is the authoritative contract a third-party
   runtime author pins against. Document: ABI input env vars and
   their semantics, briefing-file format, `result.json` schema and
   field semantics, side effects the executor performs, side effects
   the executor never performs, lifecycle from claim through cutoff,
   failure semantics, examples (minimal happy-path executor in
   pseudocode).

2. **`CLAUDE.md` split** — workflow rules stay in `CLAUDE.md` for
   human readers. Runtime-injected guidance (anything that today is
   read by Claude as task-execution context — quality bar, briefing
   shape, etc.) moves out. The actual mechanism for this depends on
   how the briefing template was structured in T2; T4 reflects the
   final state in `CLAUDE.md`.

3. **Operator guide update** — describe the new docker-compose entry
   point, the two-image structure (and the bundled-binary day-1
   shortcut), and the legacy paths that have been deleted.

4. **`handoffs/agent-runtime-split.md`** — final state record: new
   package layout, new image refs, deleted paths, smoke-gate result,
   open follow-ons (T5 if not yet merged, K8s/GHA template
   re-introduction if needed).

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Flesh out `runtime/abi/docs/abi-spec.md` per the structure outlined in technical-design §4.2 and §4.3
- [ ] Verify `CLAUDE.md` workflow rules are unchanged; runtime-injection content removed in T2 is correctly reflected
- [ ] Update operator guide (`runtime/orchestrator/docs/OPERATOR-GUIDE.md` or equivalent) for the new docker-compose entry point and image structure
- [ ] Note in operator guide that K8s CronJob and GH Actions templates were deleted in T2 and require a follow-on feature to re-introduce
- [ ] Write `handoffs/agent-runtime-split.md` recording new package layout, new image refs, deleted paths, smoke-gate outcome
- [ ] Cross-link the abi-spec doc from operator guide and from `CLAUDE.md` (so future runtime authors have a single jump-off point)

---

## T5 — Orchestrator code quality pass

### Description

After T2's split lands, the new `runtime/orchestrator/` package has
clear boundaries and the cleanups exposed by the split become
visible. T5 is a focused refactor PR against
`runtime/orchestrator/` only.

T5's concrete checklist is **populated by T2's final subtask** —
when T2's PR is being authored, a fresh-eyes pass over the migrated
package enumerates the specific refactor candidates and writes them
into the `### Subtasks` section below. The placeholders below are
seed candidates from technical-design §6; the real list is what T2
records.

Scope (in scope):
- Cleanups exposed by the split: dead code paths that only existed to
  bridge orchestration and execution
- Redundant re-exports
- Function granularity that no longer fits the new package boundary
- Import simplifications enabled by the new structure

Scope (out of scope):
- Library swaps
- Async/await rewrites where the existing pattern works
- Test framework changes
- Type system overhauls
- Anything in `runtime/executors/` or `runtime/abi/`

T5 does not gate the cutover. The cutover ships when T2 + T3 + T4
land. T5 follows as improvement-on-top.

### Required skills

- typescript-best-practices

### Subtasks

> Concrete checklist enumerated by T2's final-subtask fresh-eyes pass over the migrated code.

- [ ] Extract `resolveRepoLocalPath`, `resolveRepoBaseBranch`, `resolveRepoGitUrl`, `loadWorkspaceModelPolicy`, `parseManagementRepoCoords` from `src/main.ts` into `src/config/workspace-config.ts` — five helpers repeated across main, dispatch-draft-review, handle-merged-prs, auto-rebase
- [ ] De-duplicate `curlJson()` helper defined identically in `src/claim/open-workspace-pr.ts` and `src/side-effects/open-pr.ts` — extract to `src/utils/curl-json.ts`
- [ ] Extract `readTask` / `writeTask` YAML I/O pattern from `src/pr-response/dispatch-draft-review.ts` into `src/utils/task-yaml-io.ts` — same pattern exists in mutate-task-yaml and append-log
- [ ] Remove `src/adapter/adapter.ts` re-export barrel — call sites in main.ts and dispatch-draft-review.ts should import `ExecutorInput`/`ExecutorResult` directly from `@workflow/runtime-abi`
- [ ] Extract briefing-write step from `src/main.ts` (lines ~358–381: dir creation, markdown write, RAG block concat) into `src/briefing/write-briefing.ts` — reduces main.ts size and makes review-cycle briefing (dispatch-draft-review) composable from the same helper
- [ ] Consolidate duplicate briefing template structure shared by `src/briefing/agent-context.ts` and `src/pr-response/dispatch-draft-review.ts` into `src/briefing/briefing-template.ts` with reusable section builders
- [ ] Wrap the task-resolution block in `src/main.ts` dispatch loop (`resolveRepoLocalPath`, `resolveRepoGitUrl`, `resolveRepoBaseBranch`, `parseModelOverrides`, `resolveModel` — ~10 intermediate variables) into a single `resolveTaskContext()` function
- [ ] All scoped refactors verified against existing test suite (no test logic changes)
- [ ] No changes outside `runtime/orchestrator/`

---

## T6 — PR ownership split (revised D5) — executor opens impl PR; orchestrator records pr_url

### Description

Added 2026-05-02 after T4's handoff drafting revealed that the original
D5 ("orchestrator opens the PR; runtimes never call `pr-create`") was
silently violated by the implementation: the Claude executor opens the
impl PR via the `pr-create` skill (with rich PR body and test plan),
and the orchestrator's `openImplPr` is reduced to an idempotent no-op
that finds and reuses the existing PR. This task formalizes the
revised D5 — executor owns the implementation PR, orchestrator owns
the management/workspace PR — and adds `pr_url` to the ABI so the
orchestrator can record the executor-opened PR in the task YAML.

The orchestrator does **not** gate on test outcomes, and PR opening
itself is **not** gated on implementation outcome. Per D4, the
orchestrator is pure workflow-state code; the executor's internal
quality gate (tests, lint, etc.) is private to the executor. The impl
PR is part of the task lifecycle (same model as the workspace PR
opened at claim time) — opened whenever there are commits to PR,
regardless of whether tests passed. Test failure means
`terminal_status: "blocked"` with `blocked_reason: "tests_failed"`
**and** the PR is still opened (as draft, or with a failure-summary
comment) so the failed attempt is documented. `pr_url` is reported
across all terminal_status values whenever a PR exists.

The revised D5 is documented in `product-spec.md` D5 (revised
2026-05-02) and `technical-design.md` §4.6.1.

Scope:
- Add `pr_url` (string) field to the `result.json` schema
  (`runtime/abi/src/types.ts` and `schema.ts`). Reported whenever the
  executor opened an impl PR — independent of `terminal_status`.
- Update the Claude executor (`runtime/executors/claude/src/index.ts`)
  to:
  - Always invoke the impl-PR-open path whenever there are commits on
    the feature branch — regardless of whether tests passed. The PR
    is part of the task lifecycle, not an artifact of test outcome.
  - Extract the PR URL from Claude's stdout (the `pr-create` skill
    reports the PR URL it opens) and populate `result.json.pr_url`
    whenever a PR was opened.
  - When Claude's test plan reports failures, write
    `terminal_status: "blocked"` with `blocked_reason: "tests_failed"`
    AND `pr_url` (the PR documents the failed attempt — possibly as
    draft or with a failure-summary comment).
- Update orchestrator dispatch (`runtime/orchestrator/src/side-effects/dispatch.ts`):
  - Remove the call to `openImplPr`.
  - Whenever `result.pr_url` is present, pass it to `mutateTaskYaml`
    to record in the task YAML's `pr.url` field — regardless of
    `terminal_status`. A blocked task with a draft PR still records
    its `pr_url`.
  - No new gating logic — `terminal_status` translation paths
    (in_review / blocked / failed) are unchanged.
- Delete `runtime/orchestrator/src/side-effects/open-pr.ts` and remove
  its imports.
- Update `runtime/abi/docs/abi-spec.md` to document the revised D5,
  the new `pr_url` field, and the executor's PR-open responsibility.
- Update `runtime/executors/claude/src/CLAUDE.md` (or equivalent
  briefing template) to make the impl-PR-open step an explicit
  executor responsibility, applied regardless of test outcome.

Out of scope:
- Removing `pr-create` skill from Claude's loaded skills — it is the
  executor's PR-opener and remains in scope.
- Changing the workspace-PR opening logic (`open-workspace-pr.ts`) —
  it stays orchestrator-owned, unchanged.
- Adding any test-outcome inspection to the orchestrator — orchestrator
  is workflow-state-only and does not know about tests.
- Migrating existing impl PRs (#58, #59, #60, #62, #63) — they remain
  as merged history.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] `runtime/abi/src/types.ts`: add `pr_url?: string` field to `ExecutorResult`. Document semantics in JSDoc — populated whenever the executor opened a PR, regardless of terminal_status.
- [ ] `runtime/abi/src/schema.ts`: extend the JSON Schema to validate `pr_url`. Optional across all terminal_status values (a task may legitimately produce no PR if no commits were made).
- [ ] `runtime/abi/src/types.test.ts` and `schema.test.ts`: extend tests to cover `pr_url` across multiple terminal_status values (in_review with pr_url, blocked with pr_url, failed without pr_url).
- [ ] `runtime/executors/claude/src/index.ts`: extract PR URL from Claude stdout (look for `https://github.com/.../pull/<n>` emitted by `pr-create` skill). Always populate `pr_url` when a PR was opened, regardless of test outcome. On test failure, write `terminal_status: "blocked"` with `blocked_reason: "tests_failed"` AND `pr_url` (the PR documents the failed attempt).
- [ ] `runtime/executors/claude/src/index.test.ts`: add unit tests for the PR URL extraction helper. Use the existing `extractTokenUsage` test pattern.
- [ ] `runtime/orchestrator/src/side-effects/dispatch.ts`: remove the `openImplPr` call. Read `pr_url` from `result.json` whenever it is present and pass it to `mutateTaskYaml` — on any terminal_status. No conditional gating.
- [ ] `runtime/orchestrator/src/side-effects/dispatch.test.ts`: update tests — `pr_url` from result.json is recorded in task YAML across multiple terminal_status values. Verify no impl PR is opened by the orchestrator.
- [ ] Delete `runtime/orchestrator/src/side-effects/open-pr.ts` and any tests targeting it.
- [ ] Remove the import of `openImplPr` from `dispatch.ts`.
- [ ] Update `runtime/abi/docs/abi-spec.md` to document revised D5 — new `pr_url` field, executor's PR-open responsibility, the lifecycle-not-outcome framing for both PRs.
- [ ] Update `runtime/executors/claude/src/CLAUDE.md` (or executor briefing template) to make impl-PR-open an explicit executor step applied regardless of test outcome.
- [ ] Run full test suite — all ABI, orchestrator, and executor tests must pass.
- [ ] Drive one real task end-to-end through the new shape on a non-production workspace to verify: executor opens PR with rich body, orchestrator records `pr_url` from `result.json` for both passing and failing test scenarios, no duplicate impl PR is opened, no orchestrator-side test inspection.
