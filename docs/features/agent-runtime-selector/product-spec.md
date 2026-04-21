# Product Specification

## Feature
- Feature ID: `agent-runtime-selector`
- Title: Agent Runtime Selector — Claude Code vs Hermes

## Problem

Every task in the workflow runs on Claude Code today. Claude Code is powerful and well-suited to complex reasoning tasks, but it carries a non-trivial API cost per task. Many tasks in the workflow are routine and mechanical — status log writes, boilerplate code generation, doc updates, simple refactors — where a cheaper or free runtime would produce equally good output.

Hermes Agent (NousResearch, MIT license) is a self-hostable agent platform that supports local LLMs via Ollama or llama.cpp. Running Hermes with a local Hermes 3 model costs nothing beyond compute. Both Claude Code and Hermes support MCP natively, meaning the RAG tools, task state tools, and any other MCP integrations work identically across both runtimes.

There is no mechanism today to route a task to a different runtime based on its complexity or cost profile. All tasks pay Claude API cost regardless of whether they need it.

## Goals

1. **Pluggable runtime per task** — introduce `execution.runtime` on task YAMLs; valid values: `claude-code` (default) | `hermes`
2. **Backward compatibility** — tasks without `execution.runtime` set default to `claude-code`; no existing task breaks
3. **`start-implementation` branching** — skill reads `execution.runtime` and invokes the correct runtime; Claude Code path is unchanged; Hermes path invokes the Hermes CLI with equivalent context
4. **Skill compatibility** — `SKILL.md` context is injected into both runtimes; a translation layer converts SKILL.md content into Hermes-compatible system prompt or skill format at invocation time
5. **MCP parity** — MCP tools (`rag_query`, etc.) configured identically for both runtimes; no tool loses functionality based on runtime choice
6. **Cost routing guidance** — document which task types are suited for each runtime so tech leads can assign `execution.runtime` intentionally during task planning

## Non-goals

- Not replacing Claude Code — it remains the default and the right choice for complex tasks
- Not auto-routing tasks based on content analysis — runtime is set explicitly by the tech lead at task planning time
- Not supporting more than two runtimes in v1 of this feature
- Not self-hosting the Hermes LLM backend as part of this feature — operators bring their own Ollama/llama.cpp setup

## Success criteria

- A task with `execution.runtime: hermes` is claimed and executed by Hermes Agent without manual intervention
- A task with `execution.runtime: claude-code` or no runtime field behaves identically to today
- SKILL.md context is available to the Hermes runtime at task start
- MCP tools return identical results regardless of which runtime calls them
- Operators can run a full feature end-to-end with mechanical tasks on Hermes and complex tasks on Claude, reducing total API cost
