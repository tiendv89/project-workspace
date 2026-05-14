# Technical Design

## Feature
- Feature ID: `executor-self-briefing`
- Title: Executor-owned briefing — move prompt construction out of the orchestrator

---

## 1. Current State

### Orchestrator briefing module

The orchestrator owns a `runtime/orchestrator/src/briefing/` module (5 files):

| File | Purpose |
|---|---|
| `agent-context.ts` | `generateBriefing()` — impl executor prompt |
| `fix-briefing.ts` | `generateFixBriefing()` — fix executor prompt |
| `reviewer-briefing.ts` | `generateReviewerBriefing()` — reviewer executor prompt |
| `briefing-template.ts` | Shared section builders (`preambleSection`, `identitySection`, `taskContextSection`, etc.) |
| `write-briefing.ts` | `writeBriefing()` — writes content to `/tmp/briefing-{taskId}/briefing.md` |

### Transport and ABI

- `BriefingTransportPort` is defined in `runtime/abi/src/ports.ts` with `put()` and `cleanup()` methods.
- `LocalFileBriefingAdapter` (`runtime/orchestrator/src/adapters/briefing/local-file.ts`) implements it by writing to `tmpdir()`.
- `ExecutorInput` in `runtime/abi/src/types.ts` has `briefingPath: string` as a required field.
- The ABI spec (`runtime/abi/docs/abi-spec.md`) lists `BRIEFING_PATH` as a required env var.

### Call sites in the orchestrator

**`main.ts`** (implementation + fix executor dispatch):
```
line 536: generateBriefing(opts) → briefingContent
line 554: ports.briefing.put(taskId, briefingContent) → briefingPath
line 562: briefingPath passed to buildAndSubmitExecutor()
line 622: generateFixBriefing(opts) → fixContext
line 638: ports.briefing.put(taskId, fixContext) → fixBriefingPath
line 644: fixBriefingPath passed to buildAndSubmitExecutor()
line 709: inline rebase briefing string built (4-line Markdown, no generated function)
line 715: ports.briefing.put(`rebase-${taskId}-${handle}`, rebaseBriefingContent) → rebaseBriefingPath
line 729: rebaseBriefingPath passed into ExecutorPortInput for kind="rebase" executor
```

> **Note (verified 2026-05-14):** The `agent-runtime-redesign` feature added a `kind="rebase"` executor path in `main.ts`. Its briefing is an inline string (not from a briefing module function) but still written via `ports.briefing.put`. This path was absent from the original design and must be included in the removal scope.

**`dispatch-reviewer.ts`** (reviewer executor dispatch):
```
line 197: generateReviewerBriefing(opts) → reviewerBriefing
line 214: writeBriefing({ taskId: `reviewer-${taskId}`, briefingContent }) → { briefingPath }
line 228: briefingPath passed into ExecutorPortInput
```

### Claude executor

`runtime/executors/claude/src/index.ts` reads `BRIEFING_PATH` (line 288), then reads the file (line 379). The content is passed as the initial prompt to Claude with a hard-stop rule appended.

The briefing is Claude-specific Markdown: it instructs Claude to run `/start-implementation {taskId}` and includes identity, task context, model directive, rules, and checkpoint discipline. This is executor-private knowledge the orchestrator should not own.

### Constraints

- `runtime/abi/src/types.ts` is the single source of truth for the executor contract. Changing it requires updating `abi-spec.md`, `fake-ports.ts`, and all tests that construct `ExecutorPortInput`.
- No ABI version constant exists yet; the version bump is a documentation/changelog change in `abi-spec.md`.
- The executor already clones the mgmt repo early in its lifecycle (`index.ts` line 166), so all workspace docs are available before the briefing is needed.

---

## 2. Problem Framing

**What must change:**
- The orchestrator must have zero knowledge of briefing content, prompt format, or Claude-specific instructions.
- `ExecutorInput.briefingPath` must be removed — passing a pre-built prompt path is itself an expression of orchestrator knowledge about the executor.
- The executor must assemble its own prompt from the mgmt repo it already clones.

**What must remain stable:**
- `ExecutorInput` fields for task identity (`taskId`, `featureId`, `mgmtRepoUrl`, etc.) remain unchanged.
- The executor's output contract (`result.json`, `terminal_status`, `pr_url`) is unchanged.
- The orchestrator's scheduling, polling, and lifecycle logic is unchanged.
- RAG pre-flight injection is out of scope.

**Fixed assumptions:**
- The mgmt repo clone happens before the briefing step in every executor type — the executor always has workspace docs available.
- The Claude executor is the only executor today; this design makes room for others without implementing multi-executor routing.

---

## 3. Options Considered

### Option A — Flat self-assembly in executor (single function, no new files)
Add `buildBriefing()` directly in `runtime/executors/claude/src/index.ts`.

- **Pros**: Minimal file surface.
- **Cons**: `index.ts` grows significantly; briefing assembly is untestable in isolation; impl/fix/reviewer variants make the file unwieldy over time.
- **Implementation impact**: Moderate — one file change.

### Option B — Briefing module in the executor (move, not redesign)
Move `runtime/orchestrator/src/briefing/` into `runtime/executors/claude/src/briefing/`. The module reads `tasks.md`, task YAML, `technical-design.md`, and `CLAUDE.md` from the already-cloned mgmt dir. `index.ts` calls `buildBriefing()` from this module.

- **Pros**: Mirrors existing structure; each briefing variant stays in its own file; fully unit-testable; clean ownership line.
- **Cons**: More files; reviewer executor path must also be migrated.
- **Implementation impact**: Moderate — move + adapt 5 files, update callers.

### Option C — Init-agent skill delegation
Pass only the task reference to Claude; let Claude run an `init-agent` skill that reads context and determines what to do.

- **Pros**: Fully autonomous.
- **Cons**: Requires `init-agent` to be production-ready; adds latency (extra Claude round-trip); harder to audit; out of scope.
- **Implementation impact**: High — blocked on `init-agent` maturity.

---

## 4. Chosen Design

**Option B — Briefing module in the executor.**

The orchestrator briefing module is moved into `runtime/executors/claude/src/briefing/`. The orchestrator retains zero briefing logic. `briefingPath` is removed from `ExecutorInput`. After cloning the mgmt repo, the executor calls `buildBriefing(mgmtDir, kind, opts)` locally.

### Why Option B
The briefing content is a Claude implementation detail — it belongs in the Claude executor package. Moving (not redesigning) the module keeps risk surface small: the template logic is proven; only the ownership and file-read source change. Option A defers the mess; Option C is a separate feature.

### New executor briefing flow

```
Orchestrator                    Claude Executor (index.ts)
─────────────                   ──────────────────────────
dispatch(ExecutorInput)  ──▶    requireEnv: TASK_ID, FEATURE_ID, MGMT_REPO_URL, ...
  (no briefingPath)             clone mgmt repo → mgmtDir
                                read tasks.md, task YAML, technical-design.md, CLAUDE.md
                                buildBriefing(mgmtDir, "impl" | "fix" | "reviewer", opts)
                                → briefingContent string
                                spawn claude --append-system-prompt briefingContent ...
```

### What is removed from the orchestrator

| Artifact | Action |
|---|---|
| `runtime/orchestrator/src/briefing/` (all 5 files) | Delete entirely |
| `BriefingTransportPort` in `runtime/abi/src/ports.ts` | Remove interface |
| `LocalFileBriefingAdapter` (`runtime/orchestrator/src/adapters/briefing/local-file.ts`) | Delete file |
| `ports.briefing` field in `RuntimePorts` | Remove |
| `briefing.put(...)` calls in `main.ts` (impl, fix, and rebase paths) and `dispatch-reviewer.ts` | Remove |
| `briefingPath` in `ExecutorInput` | Remove field |
| `BRIEFING_PATH` row in `runtime/abi/docs/abi-spec.md` | Remove; add changelog note |
| `BRIEFING_PATH` in `subprocess.ts` and `claude-docker-run.ts` env setup | Remove |
| `briefing: new LocalFileBriefingAdapter()` in `local-docker.ts` | Remove (verified present alongside `local-subprocess.ts`) |

### What is added to the executor

| Artifact | Action |
|---|---|
| `runtime/executors/claude/src/briefing/briefing-template.ts` | Move from orchestrator |
| `runtime/executors/claude/src/briefing/agent-context.ts` | Move + adapt (reads mgmt repo files) |
| `runtime/executors/claude/src/briefing/fix-briefing.ts` | Move + adapt |
| `runtime/executors/claude/src/briefing/reviewer-briefing.ts` | Move + adapt |
| `runtime/executors/claude/src/briefing/rebase-briefing.ts` | New — builds rebase context from env vars (`TASK_REPO_BRANCH`, `TASK_BASE_BRANCH`); no mgmt repo clone needed |
| `runtime/executors/claude/src/index.ts` | Replace `requireEnv("BRIEFING_PATH")` + file read with `buildBriefing()` call; dispatch to rebase variant when `KIND=rebase` |

### ABI version

No version constant exists. Update `runtime/abi/docs/abi-spec.md`: remove the `BRIEFING_PATH` row from the inputs table and add a changelog section noting the removal.

### Affected repositories

| Repo | `workspace.yaml` id | Changes |
|---|---|---|
| tiendv89/agent-workflow | `workflow` | All changes above — no other repos |

---

## 5. Dependency Analysis

| Dependency | Status | Notes |
|---|---|---|
| `runtime/abi/src/types.ts` — remove `briefingPath` | Internal | Gates T2, T3, T4 — must land first in the same branch |
| Orchestrator compile-cleanliness after ABI change | Internal | T2 + T3 together restore it |
| Executor compile-cleanliness after ABI change | Internal | T4 restores it |
| Test suite | Internal | T5 cleans up after T2/T3/T4 |
| RAG pre-flight injection | Out of scope | Orchestrator still runs RAG pre-flight; unchanged |
| `local-docker` profile | Out of scope | Not touched |
| `platform-byo-executor` feature | Downstream | This feature's ABI simplification makes BYO executor easier; no blocker created |

No external or vendor dependencies. No blocking decisions outstanding.

---

## 6. Parallelization / Blocking Analysis

```
T1: ABI contract — remove briefingPath from ExecutorInput, update abi-spec.md + fake-ports.ts
  └── Can begin now — no blockers

  T2: Orchestrator — delete briefing/ module, remove calls in main.ts + dispatch-reviewer.ts,
      remove BriefingTransportPort from RuntimePorts + local-subprocess profile
      └── BLOCKED on T1 (briefingPath must be gone from the type before call-site removals;
          TypeScript rejects passing a field that no longer exists in the input type)

  T3: Adapters — remove BRIEFING_PATH from subprocess.ts and docker-run.ts env setup
      └── BLOCKED on T1 (both adapters destructure briefingPath from ExecutorPortInput;
          removing it before the type change causes a compile error)

  T4: Claude executor — move briefing/ module in, replace BRIEFING_PATH read with buildBriefing()
      └── BLOCKED on T1 (requireEnv("BRIEFING_PATH") removal must match the updated
          ExecutorInput shape or the executor will fail at runtime on a field that no longer exists)

  T2, T3, and T4 run in parallel after T1.

  T5: Tests — delete orchestrator briefing tests, update dispatch/subprocess/seam tests,
      add executor self-briefing unit tests
      └── BLOCKED on T2 (orchestrator briefing test files reference deleted module)
      └── BLOCKED on T3 (adapter fixture inputs no longer include briefingPath)
      └── BLOCKED on T4 (new executor briefing module must exist to write tests against)
```

---

## 7. Repository Impact

Only `workflow` (`tiendv89/agent-workflow`) is affected.

**Touched paths:**

```
runtime/abi/src/types.ts                                   remove briefingPath field
runtime/abi/src/ports.ts                                   remove BriefingTransportPort
runtime/abi/src/fake-ports.ts                              remove briefingPath from fakeInput
runtime/abi/docs/abi-spec.md                               remove BRIEFING_PATH row, add changelog
runtime/orchestrator/src/briefing/                         DELETE entire directory (5 files)
runtime/orchestrator/src/adapters/briefing/local-file.ts   DELETE
runtime/orchestrator/src/main.ts                           remove generateBriefing calls + put calls
runtime/orchestrator/src/pr-response/dispatch-reviewer.ts  remove generateReviewerBriefing + writeBriefing
runtime/orchestrator/src/runtime-ports.ts                  remove briefing port field
runtime/orchestrator/src/profiles/local-subprocess.ts      remove LocalFileBriefingAdapter
runtime/orchestrator/src/adapters/executor/subprocess.ts      remove BRIEFING_PATH from env
runtime/orchestrator/src/adapters/executor/claude-docker-run.ts  remove BRIEFING_PATH from env
runtime/orchestrator/src/profiles/local-docker.ts             remove LocalFileBriefingAdapter wiring
runtime/executors/claude/src/briefing/                        NEW — moved + adapted from orchestrator
runtime/executors/claude/src/briefing/rebase-briefing.ts      NEW — rebase variant (env-var derived)
runtime/executors/claude/src/index.ts                         replace BRIEFING_PATH read with buildBriefing(); handle KIND=rebase
runtime/orchestrator/tests/agent-context.test.ts           DELETE
runtime/orchestrator/tests/fix-briefing.test.ts            DELETE
runtime/orchestrator/tests/reviewer-briefing.test.ts       DELETE
runtime/orchestrator/tests/dispatch-reviewer.test.ts       update — no briefingPath in fixtures; remove briefing file assertions
runtime/orchestrator/tests/subprocess-w3.test.ts           update — no briefingPath in fixtures
runtime/orchestrator/tests/seam-executor-dispatch.test.ts  update — no briefingPath in fixtures
runtime/orchestrator/tests/adapters.test.ts                update — remove LocalFileBriefingAdapter tests
runtime/abi/tests/fake-ports.test.ts                       update — no briefingPath in fakeInput
runtime/executors/claude/tests/briefing/                   NEW — unit tests for buildBriefing variants (impl, fix, reviewer, rebase)
```

---

## 8. Validation and Release Impact

### Testing expectations

- Existing orchestrator briefing tests (`agent-context.test.ts`, `fix-briefing.test.ts`, `reviewer-briefing.test.ts`) are deleted — they test logic that no longer lives in the orchestrator.
- New unit tests in `runtime/executors/claude/tests/briefing/` cover `buildBriefing()` for impl, fix, and reviewer variants with a fixture mgmt repo directory.
- Dispatcher and adapter tests updated to omit `briefingPath` from fixture inputs.
- Full test suite (`npm test` in the `workflow` repo root) must pass before PR opens.

### Migration / config impact

None for operators. `BRIEFING_PATH` was orchestrator-internal — no operator ever set it directly. The visible env var surface is unchanged.

### Rollout concerns

This is a breaking ABI change: an old executor that still reads `BRIEFING_PATH` will fail with `requireEnv` if deployed against a new orchestrator that no longer sets it. Orchestrator and executor must be deployed together. Both packages live in the same `workflow` monorepo — a single merge + deploy handles this.

No staged rollout required; no data migration involved.

### Backward compatibility

None maintained intentionally. `BRIEFING_PATH` is removed from the ABI. The spec changelog records the removal for third-party runtime authors.
