# Product Specification

## Feature
- Feature ID: `hermes-skill-adaptation`
- Title: Hermes Skill Adaptation — Convert workflow and technical skills for Hermes executor

## Background

`adding-hermes-executor` delivered Hermes as a second executor. `executor-capability`
extended it to handle review tasks. `executor-self-briefing` moved prompt construction
into the executor itself so the orchestrator stays model-agnostic.

The result: Hermes can run tasks end-to-end — but its output quality lags Claude's.

## Problem

All workflow skills (`.claude/skills/`) and technical skills (`technical_skills/`) in
the workflow repo were authored for Claude Code. They rely on patterns that are
invisible assumptions about Claude's instruction-following behaviour:

- **Slash commands** (`/start-implementation`, `/pr-create`) — Claude Code CLI-specific;
  Hermes has no concept of these.
- **MCP tool names** (`mcp__gitnexus__query`, `mcp__rag-server__rag_query`) — Claude
  tool-call syntax; Hermes uses different tool invocation conventions.
- **Claude-specific directives** ("Think step by step", thinking-mode cues, continuation
  prompts) — written for Claude's reasoning style; may not transfer to Hermes's LLM.
- **Assumed tool availability** — skills reference tools (Read, Edit, Bash, WebFetch)
  that exist in Claude Code's built-in tool set; Hermes exposes different primitives.
- **CLAUDE.md injection** — Claude Code automatically injects `CLAUDE.md` into context;
  Hermes only sees what the wrapper briefing passes explicitly.

Because none of this was adapted when Hermes was introduced, Hermes executor tasks
run with skills that were never designed for it — and it shows.

## Goals

1. **Skill gap audit** — systematically compare all workflow skills and technical skills
   against Hermes's actual capabilities (tool set, invocation syntax, context injection
   mechanism). Produce a structured audit: what is Claude-specific, what is portable
   as-is, what requires adaptation.

2. **Hermes-compatible skill format** — define a skill format that Hermes can consume
   effectively. This does not mean duplicating every skill file; it means identifying
   the translation layer (if any) and the rules for writing skills that work for both
   executors, or for writing Hermes-specific variants where the gap is too large.

3. **Adapt core workflow skills** — convert the skills that the Hermes executor uses
   on every task (`start-implementation` equivalent, `pr-create` equivalent, task state
   protocol) into a Hermes-compatible form. These are the highest-leverage skills
   because every Hermes task depends on them.

4. **Adapt high-value technical skills** — convert the most-used technical skills
   (e.g. `backend-engineer`, `typescript-best-practices`, `go-best-practices`,
   `python-best-practices`) into Hermes-compatible form. The criteria for "high-value"
   is: used in the most tasks, or most likely to produce divergent output without
   adaptation.

5. **Skill routing in the executor** — update the Hermes executor wrapper to load the
   appropriate skill variant (Hermes-native or adapted) for each task, rather than
   passing Claude-flavoured skill content verbatim. The wrapper already owns the
   briefing construction — this extends that ownership to skill loading.

6. **Validation** — run at least one real impl task and one real review task through the
   adapted Hermes executor and confirm output quality is meaningfully better than the
   unadapted baseline. Produce a before/after comparison in the handoff.

## Non-goals

- Replacing all Claude skill content — Claude-specific skills remain in place for the
  Claude executor. This feature adds a Hermes layer; it does not remove the Claude layer.
- Achieving full parity with Claude quality on every task type — the goal is measurable
  improvement, not perfection.
- Changing the orchestrator — skill adaptation lives entirely in the executor wrapper
  and the workflow repo's skill files. The orchestrator is not touched.
- Writing skills for every executor imaginable — this feature focuses on Hermes. A
  general multi-executor skill framework is deferred.

## Success criteria

- Audit doc covers every workflow skill and every technical skill with a clear
  `portable | adapt | hermes-variant` label.
- Core workflow skills (`start-implementation`, `pr-create`, task state protocol) have
  Hermes-compatible versions loadable by the executor wrapper.
- At least 4 high-value technical skills have Hermes-compatible versions.
- A real Hermes impl task completes with output that passes reviewer rubric without
  manual intervention — something the unadapted executor was failing.
- Handoff includes a before/after quality comparison.
