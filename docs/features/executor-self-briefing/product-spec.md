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

The orchestrator currently violates the boundary between scheduling and execution:

- It knows which slash commands the Claude executor accepts (`/start-implementation`, etc.).
- It knows the executor's recovery protocol and how to instruct it to write `result.json`.
- It assumes a specific LLM tool chain and prompt format when constructing briefings.
- It owns and transports the entire prompt, meaning every new executor type requires a new
  `generate*Briefing()` branch in the orchestrator.

A task router should not know what kind of agent it is dispatching to. It should hand off
a task reference and step back.

## Goals

1. **Orchestrator knows nothing about the executor.** It does not know what model, what
   tools, what slash commands, or what prompt format the executor uses. It has no
   `generate*Briefing()` logic of any kind.

2. **Executor input is a minimal task reference only.** `ExecutorPortInput` contains the
   task ID, feature ID, and management repo URL — nothing else. No briefing content, no
   model directives, no slash command hints.

3. **The executor owns its entire LLM process.** Given the task reference, it clones the
   management repo, reads whatever context it needs (`tasks.md`, task YAML,
   `technical-design.md`, `CLAUDE.md`, etc.), and constructs its own prompt. The
   orchestrator has no visibility into or opinion about how that happens.

### Concrete removals (ABI change — bump ABI version)

- Delete `generateBriefing()`, `generateFixBriefing()`, `generateReviewerBriefing()`.
- Remove `BriefingTransportPort` from `RuntimePorts`; delete `LocalFileBriefingAdapter`.
- Remove `briefingPath` from `ExecutorPortInput`.

## Non-goals

- Changing the orchestrator's scheduling, dispatch, or lifecycle logic.
- Changing how the executor writes `result.json` or calls back to the broker.
- Supporting multiple simultaneous executor types in a single deployment (this refactor
  makes it structurally possible; a follow-on feature can implement it).
- Changing RAG pre-flight injection strategy.
- Fixing or removing the `local-docker` executor profile — out of scope for this feature.
