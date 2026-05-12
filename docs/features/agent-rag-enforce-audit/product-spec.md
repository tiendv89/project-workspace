# Product Specification

## Feature
- Feature ID: `agent-rag-enforce-audit`
- Title: RAG & GitNexus enforce + audit — hook-based enforcement and tamper-proof mid-task query logging

## Problem

The RAG and GitNexus lookup-first rules exist in `CLAUDE.md` and are available to every executor via `copyWorkspaceClaude` / `setupGlobalSkills`. Despite this, agents consistently skip them and reach for `Read` or `grep` directly.

The root cause is that **text rules are not enforcement mechanisms**. The model's training bias toward `Read` is stronger than any instruction in a markdown file. This produces two concrete failures:

1. **No enforcement** — agents perform redundant file reads for content RAG already has indexed, burning tokens and context on re-discovery work. GitNexus structural lookups (callers, call graph, impact) are skipped in favour of grep, which gives no structural context.

2. **No mid-task audit** — when an agent does call `mcp__rag-server__rag_query` or `mcp__gitnexus__*` mid-task, there is no record of it. The only audited RAG event is the pre-inject `rag_pre_flight` entry written by the orchestrator before the executor spawns. Mid-task queries — whether made correctly or not made at all — are invisible.

The pre-inject audit exists and works. The mid-task layer has neither enforcement nor visibility.

## Goals

1. **Enforce RAG-first via Claude Code hooks** — install a `PreToolUse` hook on `Read` (and `Bash` grep patterns) so that every file lookup triggers a RAG query first. If RAG returns a confident result, the file read is augmented or replaced. Enforcement is mechanical — it cannot be skipped by agent behaviour.

2. **Enforce GitNexus-first for code symbols** — for `Read` calls on `.ts`, `.py`, `.go`, and other source files, additionally run a `mcp__gitnexus__context` lookup. The agent sees structural context (callers, callees, processes) alongside or before the raw file content.

3. **Audit mid-task RAG calls — server side** — the RAG server logs every `rag_query` call: timestamp, `workspace_id`, query text, `source_types` filter, top-k, and result scores. This log is the tamper-proof record — it captures all queries regardless of whether the agent wrote a task log entry.

4. **Audit mid-task GitNexus calls — server side** — the GitNexus server logs every query and context call with the same fields.

5. **Surface both audits in one place** — after each executor run, the orchestrator reads the server-side query logs for that task's execution window and appends a `rag_mid_task_summary` entry to the task YAML log. This makes pre-inject + mid-task both visible in the same audit trail.

6. **Git-tracked source of truth for hook configuration** — `~/.claude/settings.json` is not tracked by git. The hook configuration template lives in `workflow/templates/claude-settings.json` (git-tracked) and is written to `~/.claude/settings.json` at executor spawn time by a new `setupGlobalSettings` function, following the same pattern as `copyWorkspaceClaude`.

## Non-goals

- Not changing the `rag_query` MCP tool contract or return shape
- Not replacing the pre-inject `rag_pre_flight` mechanism — it stays; this feature adds the mid-task layer alongside it
- Not enforcing RAG for non-indexed content (binary files, generated files, lock files)
- Not blocking the executor if RAG or GitNexus is unavailable — hooks degrade gracefully (log a warning, allow the tool call through)
- Not building a general query analytics dashboard — server-side logs are the raw record; surfacing is limited to per-task YAML summary

## Success criteria

- An agent that would have called `Read` on an indexed file instead receives RAG results first, without any instruction from the task briefing
- Every `rag_query` call during executor runtime appears in the server-side query log with full metadata
- After a task completes, the task YAML log contains a `rag_mid_task_summary` entry listing how many mid-task RAG and GitNexus calls were made and their average confidence score
- `workflow/templates/claude-settings.json` is committed and used as the source of truth — no manual `~/.claude/settings.json` edits required

## Dependency

None. This feature is independent of `agent-rag-v3` and can proceed in parallel.
The hook scripts will benefit from `agent-rag-v3`'s hybrid search (better results = more useful enforcement) but do not require it.
