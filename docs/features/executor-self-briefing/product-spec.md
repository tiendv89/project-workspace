# Product Specification

## Feature
- Feature ID: `executor-self-briefing`
- Title: Executor-owned briefing — move prompt construction out of the orchestrator

## Background

The orchestrator currently builds the full prompt for every executor before spawning it.
Three functions handle this today:

- `generateBriefing()` — impl executor
- `generateFixBriefing()` — fix executor
- `generateReviewerBriefing()` — reviewer executor

Each function produces Claude-specific Markdown containing slash commands
(`/start-implementation`), checkpoint-discipline rules, and model directives. The result
is written to a temp file and the **file path** is passed to the executor container via
the `BRIEFING_PATH` env var.

## Problem

### 1. Orchestrator is coupled to Claude's prompt format

The orchestrator knows what slash commands the Claude executor accepts, what its recovery
protocol looks like, and how to instruct it to write `result.json`. This is the executor's
responsibility, not the orchestrator's.

If a second executor type is introduced (different model provider, different runtime) the
orchestrator would need a new `generate*Briefing()` branch for each one. The scheduling
engine should not care what agent it is dispatching to.

### 2. Briefing file transport breaks in local-docker mode

The current transport assumes the orchestrator and executor share a filesystem. In
`local-docker` mode they run in separate containers with isolated `/tmp`. Workarounds tried
so far:

- **Named Docker volume** (PR #153 last commit) — works but requires a pre-provisioned
  `briefings` volume with an explicit `name:` in compose so `docker run -v` resolves it by
  name. Adds operational surface for no architectural gain.
- **Base64 env var** — limited by OS `ARG_MAX` (~128 KB) when passed via `execFile`; risks
  silent failure on large briefings with RAG context injected.

Both are band-aids. The root cause is that the orchestrator should not own the briefing content.

### 3. The executor already has everything it needs

Every executor clones the management repo as its first step. After that clone it has direct
access to:

- `docs/features/{featureId}/tasks.md` — narrative task spec and required skills
- `docs/features/{featureId}/tasks/{taskId}.yaml` — task status and metadata
- `docs/features/{featureId}/technical-design.md` — design context
- `docs/strategy/` — domain strategy docs (when present)
- `CLAUDE.md` — workspace rules and skill list

The orchestrator writes the briefing by reading these same files and reformatting them into
a prompt. The executor could do this directly, eliminating any cross-process or
cross-container file transfer.

## Goals

- Remove `generateBriefing()`, `generateFixBriefing()`, `generateReviewerBriefing()` from
  the orchestrator.
- Remove `BriefingTransportPort` from `RuntimePorts` and delete `LocalFileBriefingAdapter`.
- Remove `briefingPath` from `ExecutorPortInput` (ABI change — bump ABI version).
- Have the Claude executor read `tasks.md`, the task YAML, and workspace docs from the
  cloned mgmt repo and construct its own prompt.
- No shared filesystem, no named volume, no env var size limits.
- The executor becomes truly self-contained: given a task ID + mgmt repo URL, it knows
  what to do without any pre-built instructions from the orchestrator.

## Non-goals

- Changing the orchestrator's scheduling, dispatch, or lifecycle logic.
- Changing how the executor writes `result.json` or calls back to the broker.
- Supporting multiple simultaneous executor types in a single deployment (this refactor
  makes it structurally possible; a follow-on feature can implement it).
- Changing RAG pre-flight injection strategy (can be passed as a structured field, separate
  from the briefing).
