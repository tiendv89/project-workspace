# Handoff — Hermes Skill Adaptation

## Summary

Adapt the workflow and technical skills under `workflow/` so they work for the
Hermes executor (not only Claude Code). The Claude-authored skills carry
implicit assumptions — slash-command invocation, `mcp__` tool-call syntax,
Claude Code's `CLAUDE.md` auto-injection — that don't transfer to Hermes.

This feature delivers:

1. A **skill classification audit** that catalogues every existing skill as
   `portable | adapt | hermes-variant` and explains why.
2. A **physical workflow-repo reorg** that gives each executor its own
   content-staging directory (`workflow/claude/` and `workflow/hermes/`) with
   an executor-agnostic env-var convention (`AGENT_RUNTIME`).
3. **Hermes-flavoured skills** for the workflow-driving skills
   (`start-implementation`, `rag-context`, `review-pr`) and six technical
   skills (TypeScript, Go, Python, backend, frontend, gitnexus-mcp).
4. **Hermes executor changes** to drop `--ignore-rules` and copy `HERMES.md`
   into the implementation directory before spawning the agent.
5. **`sync-workspace-rules`** extended with a Step B that syncs
   `HERMES.shared.md → HERMES.md` alongside the existing `CLAUDE.shared.md`
   path.

## Tasks Completed

| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Skill classification audit + precedence note | [project-workspace#273](https://github.com/tiendv89/project-workspace/pull/273) | Human close-out — three reviewer cycles all exited as `review_blocked` (stuck on the now-fixed `rag-context` skill-lookup bug in workflow#188). Audit content was spot-checked and the two stale `CLAUDE_AGENT_RUNTIME` references were refreshed after T2's rename landed. |
| T2 — Workflow repo reorg + `AGENT_RUNTIME` rename (atomic) | [agent-workflow#185](https://github.com/tiendv89/agent-workflow/pull/185) | Atomic `git mv` of `CLAUDE.shared.md`, `workflow_skills/`, `technical_skills/` under `claude/`. Env var `CLAUDE_AGENT_RUNTIME → AGENT_RUNTIME` renamed everywhere. Executor `setupGlobalSkills` extracted to its own module with unit tests. Landed as `[WIP]` PR after a max-turns interruption but contains the full reorg. |
| T3 — `workflow/hermes/SOUL.md` + `HERMES.shared.md` authoring | [agent-workflow#184](https://github.com/tiendv89/agent-workflow/pull/184) | Hermes-side `SOUL.md` and `HERMES.shared.md` authored as the Hermes counterpart of `CLAUDE.shared.md`, with adjustments for Hermes's tool-call conventions and lack of slash-command support. |
| T4 — Extend `sync-workspace-rules` with HERMES.md Step B | [agent-workflow#189](https://github.com/tiendv89/agent-workflow/pull/189) | Skill now performs the sync for both `CLAUDE.md` (Step A) and `HERMES.md` (Step B), reading from the respective shared docs in `workflow/claude/` and `workflow/hermes/`. |
| T5 — `workflow/hermes/workflow_skills/` | [agent-workflow#186](https://github.com/tiendv89/agent-workflow/pull/186) | Hermes-flavoured `start-implementation`, `rag-context`, `review-pr`. Slash-command invocations replaced with direct content (Hermes loads skills at spawn via `--skills`); MCP tool references rephrased in Hermes's tool-call vocabulary. |
| T6 — `workflow/hermes/technical_skills/` | [agent-workflow#187](https://github.com/tiendv89/agent-workflow/pull/187) | Six Hermes-flavoured technical skills: TypeScript, Go, Python, backend, frontend, gitnexus-mcp. Removes Claude-specific directives and Claude-Code tool-name assumptions. |
| T7 — Hermes executor Phase 3.5 + spawn changes + `.env.template` + tests | [agent-workflow#190](https://github.com/tiendv89/agent-workflow/pull/190) | Drops `--ignore-rules` from the Hermes spawn (so `HERMES.md` actually loads). Adds Phase 3.5 that copies `<mgmtRoot>/HERMES.md → <implDir>/HERMES.md` before each agent. New env template entries and integration tests. |

## Deviations from Technical Design

- **T8 cancelled.** The original task breakdown included a T8 — _"Validation: real impl + real review, before/after comparison"_ — as an agent-executed task. Reclassified during handoff as a human verification step rather than an agent task, since the comparison requires subjective judgement (output quality, behaviour parity) that is not auditable by the autonomous reviewer. The actual validation pass is still required, but it lives outside the feature scope as a manual operator action.
- **T1 reviewer cycles all blocked.** Three reviewer cycles on T1 exited as `review_blocked` (stuck on the `rag-context` skill-lookup bug in the eligibility check). The bug was fixed and merged in workflow#188 _during_ this feature's implementation, but T1 had already moved to `review_incomplete` by then. T1 was closed out manually rather than re-dispatched.

## Files Changed

See the per-task PRs above for full diffs. High-level structure:

- **Workspace repo** (`project-workspace`): `docs/features/hermes-skill-adaptation/audit.md`, task YAML state, task logs, this handoff doc, the post-T2 `CLAUDE.md` sync.
- **Workflow repo** (`agent-workflow`):
  - `claude/CLAUDE.shared.md`, `claude/workflow_skills/`, `claude/technical_skills/` (moved from top-level by T2)
  - `hermes/SOUL.md`, `hermes/HERMES.shared.md`, `hermes/workflow_skills/`, `hermes/technical_skills/` (new — T3, T5, T6)
  - `runtime/executors/hermes/` (Phase 3.5, spawn changes — T7)
  - `runtime/executors/claude/src/setup-global-skills.ts` (extracted by T2)
  - `workflow_skills/sync-workspace-rules/SKILL.md` (Step B added by T4)
  - `runtime/orchestrator/tests/run-{claude,hermes}.test.ts`, `scripts/bootstrap.sh`, `scripts/install.sh`, `README.md`, `.env.template` (path / env-var fixups)

## Follow-up Items

- **T8 — Validation pass (human work).** Spin up the orchestrator with the merged feature; claim a fresh task with the Hermes executor; observe a full implementation + review cycle; compare output against the Claude executor baseline for the same task. Surface any quality regressions back into a follow-up feature.
- **Merge order for the feature → main PRs.** The workflow handoff PR ([agent-workflow#192](https://github.com/tiendv89/agent-workflow/pull/192)) needs `main` merged into the feature branch first (PRs #183, #188, #191 merged to workflow main after the feature branch was cut; the rename in T2 causes path-collision conflicts on `CLAUDE.shared.md` and `technical_skills/review-pr/SKILL.md`). Resolve those conflicts, merge workflow#192, then merge workspace [project-workspace#266](https://github.com/tiendv89/project-workspace/pull/266).
- **Rebuild the executor image.** Once both feature-branch PRs are merged, rebuild the Hermes executor container so the new `claude/`-prefixed paths and the `AGENT_RUNTIME` env var are picked up.

## Audit Trail

See the per-task `log` arrays in `docs/features/hermes-skill-adaptation/tasks/T*.yaml` for the full chronological audit. Notable orchestrator-level events:

| Event | Actor | Notes |
|---|---|---|
| Feature initialized | matthew@swellnetwork.io | 2026-05-19 (product spec drafted) |
| Product spec approved | matthew@swellnetwork.io | 2026-05-19T11:00:23+0700 |
| Technical design approved | matthew@swellnetwork.io | 2026-05-19T15:20:25+0700 |
| Tasks approved (Wave 1) | matthew@swellnetwork.io | 2026-05-19T15:30:43+0700 |
| T2 reorg merged (atomic) | Agent 2 / human | brought `claude/` layout + `AGENT_RUNTIME` rename onto the feature branch |
| T3 + T5 reverted by T2 bad merge | — | restored to `done` in a follow-up commit before T4 / T7 could proceed |
| T1 audit reviewer cycles 1–3 | reviewer agent | all exited as `review_blocked` due to `rag-context` lookup bug, fixed mid-feature in workflow#188 |
| T8 cancelled | matthew@swellnetwork.io | 2026-05-20T01:33:22+0700 — reclassified as human work |
| T1 human close-out | matthew@swellnetwork.io | 2026-05-20T01:55:20+0700 |
| Handoff PRs opened | matthew@swellnetwork.io | 2026-05-20 — workspace#266 retitled + promoted; workflow#192 opened; this handoff PR opened |
