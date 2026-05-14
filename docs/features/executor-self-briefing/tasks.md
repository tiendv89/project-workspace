# Task Breakdown — executor-self-briefing

**Feature status:** in_tdd → ready_for_implementation (pending tasks approval)
**Stage:** tasks — awaiting human approval
**Machine state:** lives in `tasks/T<n>.yaml`; this file is narrative only.

---

## Index

| ID  | Wave | Title                                    | Depends on    |
|-----|------|------------------------------------------|---------------|
| T1  | 1    | ABI contract — remove briefingPath       | —             |
| T2  | 2    | Orchestrator — delete briefing module    | T1            |
| T3  | 2    | Adapters — remove BRIEFING_PATH env      | T1            |
| T4  | 2    | Claude executor — self-briefing module   | T1            |
| T5  | 3    | Tests — delete, update, and add          | T2, T3, T4    |

---

## T1 — ABI contract — remove briefingPath

### Description

Remove `briefingPath` from `ExecutorInput` and `BriefingTransportPort` from `ports.ts`.
This is the load-bearing ABI change that gates T2, T3, and T4: TypeScript compile errors
on the removed field will surface every call site that must be cleaned up in the next wave.

Files changed:

- `runtime/abi/src/types.ts` — remove `briefingPath: string` from `ExecutorInput`
- `runtime/abi/src/ports.ts` — remove `BriefingTransportPort` interface and its `put`/`cleanup` methods
- `runtime/abi/src/fake-ports.ts` — remove `briefingPath` from the fake input fixture
- `runtime/abi/docs/abi-spec.md` — remove `BRIEFING_PATH` row from the inputs table; add a changelog section noting the removal for third-party runtime authors
- `runtime/abi/tests/fake-ports.test.ts` — remove `briefingPath: "/tmp/briefing.md"` from the fixture

After this task, `tsc --noEmit` in the ABI package should pass cleanly and the orchestrator and executor packages should have compile errors on every `briefingPath` reference — those are the correct signals for T2/T3/T4 agents.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Remove `briefingPath: string` from `ExecutorInput` in `types.ts`
- [ ] Remove `BriefingTransportPort` interface (lines 103–112) from `ports.ts`
- [ ] Remove `briefingPath` from `fake-ports.ts` fake input
- [ ] Update `abi-spec.md`: delete `BRIEFING_PATH` row, add changelog entry
- [ ] Update `fake-ports.test.ts`: remove `briefingPath` from fixture object
- [ ] Run `tsc --noEmit` in `runtime/abi/` — must pass
- [ ] Confirm downstream packages (`orchestrator`, `executors/claude`) show compile errors on `briefingPath` references (expected — T2/T3/T4 will fix them)

---

## T2 — Orchestrator — delete briefing module

### Description

Delete the orchestrator's entire briefing module and all call sites that reference it.
After this task the orchestrator has zero knowledge of briefing content or prompt format.

Files deleted:

- `runtime/orchestrator/src/briefing/agent-context.ts`
- `runtime/orchestrator/src/briefing/fix-briefing.ts`
- `runtime/orchestrator/src/briefing/reviewer-briefing.ts`
- `runtime/orchestrator/src/briefing/briefing-template.ts`
- `runtime/orchestrator/src/briefing/write-briefing.ts`
- `runtime/orchestrator/src/adapters/briefing/local-file.ts`

Files updated:

- `runtime/orchestrator/src/runtime-ports.ts` — remove `briefing: BriefingTransportPort` field (line 29) and its import
- `runtime/orchestrator/src/profiles/local-subprocess.ts` — remove `briefing: new LocalFileBriefingAdapter()` (line 72) and its import
- `runtime/orchestrator/src/profiles/local-docker.ts` — remove `briefing: new LocalFileBriefingAdapter()` (line 83) and its import
- `runtime/orchestrator/src/main.ts` — remove:
  - imports of `generateBriefing` and `generateFixBriefing` (lines 35–36)
  - impl executor briefing block (lines 534–554): `generateBriefing(...)`, `ports.briefing.put(...)`, `briefingPath` local var
  - fix executor briefing block (lines 622–638): `generateFixBriefing(...)`, `ports.briefing.put(...)`, `fixBriefingPath` local var
  - rebase executor briefing block (lines 709–729): inline string build, `ports.briefing.put(...)`, `rebaseBriefingPath` local var
  - remove `briefingPath` from `buildAndSubmitExecutor` call sites (lines 562, 644, 729)
- `runtime/orchestrator/src/pr-response/dispatch-reviewer.ts` — remove:
  - imports of `writeBriefing` and `generateReviewerBriefing` (lines 31–32)
  - reviewer briefing block (lines 197–228): `generateReviewerBriefing(...)`, `writeBriefing(...)`, `briefingPath` local var
  - remove `briefingPath` from `ExecutorPortInput` construction (line 228)

After this task, the orchestrator package must compile cleanly when T1's type change is in place.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Delete all 5 files in `runtime/orchestrator/src/briefing/`
- [ ] Delete `runtime/orchestrator/src/adapters/briefing/local-file.ts`
- [ ] Remove `briefing` port from `runtime-ports.ts` (field + import)
- [ ] Remove `LocalFileBriefingAdapter` wiring from `local-subprocess.ts` (line 72 + import)
- [ ] Remove `LocalFileBriefingAdapter` wiring from `local-docker.ts` (line 83 + import)
- [ ] Remove impl briefing block from `main.ts` (lines 534–562)
- [ ] Remove fix briefing block from `main.ts` (lines 622–644)
- [ ] Remove rebase briefing block from `main.ts` (lines 709–729)
- [ ] Remove reviewer briefing block from `dispatch-reviewer.ts` (lines 197–228)
- [ ] Run `tsc --noEmit` in `runtime/orchestrator/` — must pass (with T1 in place)

---

## T3 — Adapters — remove BRIEFING_PATH env

### Description

Remove `briefingPath` destructuring and `BRIEFING_PATH` env-var passing from the two
executor adapter files. These adapters serialize `ExecutorPortInput` fields into env vars
for the spawned process; once T1 removes `briefingPath` from the type, these lines become
compile errors.

Files updated:

- `runtime/orchestrator/src/adapters/executor/subprocess.ts`
  - Line 196: remove `briefingPath` from destructured input
  - Line 233: remove `BRIEFING_PATH: briefingPath` from the `extraEnv` / env object
- `runtime/orchestrator/src/adapters/executor/claude-docker-run.ts`
  - Corresponding destructure and env-var lines (same pattern as subprocess.ts)

After this task, both adapters compile cleanly and no longer set `BRIEFING_PATH` in the spawned process environment.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Remove `briefingPath` destructure from `subprocess.ts` input (line 196)
- [ ] Remove `BRIEFING_PATH: briefingPath` from `subprocess.ts` env object (line 233)
- [ ] Verify the corresponding lines in `claude-docker-run.ts` and remove them
- [ ] Run `tsc --noEmit` in `runtime/orchestrator/` — must pass (with T1 in place)

---

## T4 — Claude executor — self-briefing module

### Description

Move the orchestrator's briefing module into the Claude executor and adapt it to read
workspace docs from the already-cloned mgmt repo rather than receiving pre-built content
from the orchestrator. The executor becomes fully self-contained: given `TASK_ID`,
`FEATURE_ID`, and `MGMT_REPO_URL` (already in the ABI), it reads `tasks.md`, the task
YAML, `technical-design.md`, and `CLAUDE.md` directly and constructs its own prompt.

New directory: `runtime/executors/claude/src/briefing/`

Files moved and adapted (source → destination):

| Source (orchestrator)                              | Destination (executor)                               | Adaptation needed |
|----------------------------------------------------|------------------------------------------------------|-------------------|
| `briefing/briefing-template.ts`                    | `executors/claude/src/briefing/briefing-template.ts` | None — shared section builders are format-only |
| `briefing/agent-context.ts`                        | `executors/claude/src/briefing/agent-context.ts`     | Replace orchestrator-constructed string inputs with file reads from `mgmtDir` |
| `briefing/fix-briefing.ts`                         | `executors/claude/src/briefing/fix-briefing.ts`      | Same — read PR context from mgmt repo |
| `briefing/reviewer-briefing.ts`                    | `executors/claude/src/briefing/reviewer-briefing.ts` | Same |

New file:

- `runtime/executors/claude/src/briefing/rebase-briefing.ts` — builds the rebase context
  briefing from env vars (`TASK_REPO_BRANCH`, `TASK_BASE_BRANCH`). No mgmt repo clone
  needed for the rebase variant; the 4-line string the orchestrator used to build inline
  becomes a typed function here.

Entry-point change (`runtime/executors/claude/src/index.ts`):

- Remove `requireEnv("BRIEFING_PATH")` (line 288) and `readFileSync(briefingPath)` (line 379)
- After the mgmt repo clone (already happens at line 166), call `buildBriefing(mgmtDir, kind, opts)` where `kind` is derived from the `KIND` env var (`"impl"` | `"fix"` | `"reviewer"` | `"rebase"`)
- Pass the returned string directly as the initial Claude prompt (replacing the file read)

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Create `runtime/executors/claude/src/briefing/` directory
- [ ] Move + adapt `briefing-template.ts` — verify no orchestrator imports remain
- [ ] Move + adapt `agent-context.ts` — replace all string-parameter inputs with `fs.readFileSync` calls against `mgmtDir`
- [ ] Move + adapt `fix-briefing.ts` — same adaptation
- [ ] Move + adapt `reviewer-briefing.ts` — same adaptation
- [ ] Add `rebase-briefing.ts` — derive context from `TASK_REPO_BRANCH` + `TASK_BASE_BRANCH` env vars
- [ ] Export `buildBriefing(mgmtDir, kind, opts)` from `briefing/index.ts`
- [ ] Update `index.ts`: remove `requireEnv("BRIEFING_PATH")` and file read; call `buildBriefing()` after mgmt repo clone
- [ ] Handle `KIND=rebase` in `index.ts` dispatch to `rebase-briefing.ts` (no mgmt clone needed for this variant)
- [ ] Run `tsc --noEmit` in `runtime/executors/claude/` — must pass (with T1 in place)

---

## T5 — Tests — delete, update, and add

### Description

Clean up the test suite to match the new ownership boundary. Orchestrator briefing tests
are deleted (the logic no longer lives there). Fixture inputs across dispatcher and adapter
tests lose `briefingPath`. New unit tests in the executor package cover all four
`buildBriefing` variants.

Files deleted:

- `runtime/orchestrator/tests/agent-context.test.ts`
- `runtime/orchestrator/tests/fix-briefing.test.ts`
- `runtime/orchestrator/tests/reviewer-briefing.test.ts`

Files updated:

- `runtime/orchestrator/tests/adapters.test.ts` — remove `LocalFileBriefingAdapter` tests (adapter.put / adapter.cleanup assertions, lines ~148–164)
- `runtime/orchestrator/tests/dispatch-reviewer.test.ts` — remove `briefingPath` from fixture inputs; remove assertions that read the briefing file from `/tmp` (lines ~458–510)
- `runtime/orchestrator/tests/subprocess-w3.test.ts` — remove `briefingPath?: string` from fixture type (line 66) and `briefingPath: "/tmp/briefing.md"` default (line 84)
- `runtime/orchestrator/tests/seam-executor-dispatch.test.ts` — remove `briefingPath: "/tmp/briefing.md"` from fixture (line 135)
- `runtime/abi/tests/fake-ports.test.ts` — remove `briefingPath: "/tmp/briefing.md"` from fixture (line 22)

Files added:

- `runtime/executors/claude/tests/briefing/agent-context.test.ts` — unit tests for impl variant: fixture mgmt dir with stub `tasks.md`, task YAML, `technical-design.md`, `CLAUDE.md`; assert returned briefing string contains expected sections
- `runtime/executors/claude/tests/briefing/fix-briefing.test.ts` — same for fix variant
- `runtime/executors/claude/tests/briefing/reviewer-briefing.test.ts` — same for reviewer variant
- `runtime/executors/claude/tests/briefing/rebase-briefing.test.ts` — assert rebase briefing derives branch names from env vars correctly

Full test suite (`npm test` at the `workflow` repo root) must pass before PR opens.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Delete `agent-context.test.ts`, `fix-briefing.test.ts`, `reviewer-briefing.test.ts` from orchestrator tests
- [ ] Update `adapters.test.ts` — remove `LocalFileBriefingAdapter` test blocks
- [ ] Update `dispatch-reviewer.test.ts` — remove `briefingPath` fixtures and `/tmp` file assertions
- [ ] Update `subprocess-w3.test.ts` — remove `briefingPath` from fixture type and defaults
- [ ] Update `seam-executor-dispatch.test.ts` — remove `briefingPath` from fixture
- [ ] Update `abi/tests/fake-ports.test.ts` — remove `briefingPath` from fixture
- [ ] Add `executors/claude/tests/briefing/agent-context.test.ts`
- [ ] Add `executors/claude/tests/briefing/fix-briefing.test.ts`
- [ ] Add `executors/claude/tests/briefing/reviewer-briefing.test.ts`
- [ ] Add `executors/claude/tests/briefing/rebase-briefing.test.ts`
- [ ] Run full `npm test` at repo root — all tests must pass
