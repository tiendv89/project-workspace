# Product Specification

## Feature
- Feature ID: `agent-rag-enforce-audit`
- Title: RAG & GitNexus enforce — hook-based enforcement for RAG-first and GitNexus-first lookups

## Problem

The RAG and GitNexus lookup-first rules exist in `CLAUDE.md` and are available to every executor via `copyWorkspaceClaude` / `setupGlobalSkills`. Despite this, agents consistently skip them and reach for `Read` or `grep` directly.

The root cause is that **text rules are not enforcement mechanisms**. The model's training bias toward `Read` is stronger than any instruction in a markdown file:

- Agents perform redundant file reads for content RAG already has indexed, burning tokens and context on re-discovery work.
- GitNexus structural lookups (callers, call graph, impact) are skipped in favour of grep, which gives no structural context.

Once hooks enforce the behaviour mechanically, agents query RAG and GitNexus because the tool call requires it — not because a rule asked them to.

## Goals

1. **Enforce RAG-first via Claude Code hooks** — install a `PreToolUse` hook on `Read` so that every file lookup triggers a RAG query first. If RAG returns a confident result, the file read is augmented or replaced. Enforcement is mechanical — it cannot be skipped by agent behaviour.

2. **Enforce GitNexus-first for code symbols** — for `Read` calls on `.ts`, `.py`, `.go`, and other source files, additionally run a `mcp__gitnexus__context` lookup. The agent sees structural context (callers, callees, processes) alongside or before the raw file content.

3. **Git-tracked source of truth for hook configuration** — `~/.claude/settings.json` is not tracked by git. The hook configuration template lives in `workflow/templates/claude-settings.json` (git-tracked) and is written to `~/.claude/settings.json` at executor spawn time by a new `setupGlobalSettings` function, following the same pattern as `copyWorkspaceClaude`.

## Non-goals

- Not changing the `rag_query` MCP tool contract or return shape
- Not replacing the pre-inject `rag_pre_flight` mechanism — it stays unchanged
- Not enforcing RAG for non-indexed content (binary files, generated files, lock files)
- Not blocking the executor if RAG or GitNexus is unavailable — hooks degrade gracefully (log a warning, allow the tool call through)
- Not auditing mid-task RAG or GitNexus calls — once enforcement is mechanical, agents query because the hook requires it; a separate audit trail is unnecessary overhead

## Success criteria

- An agent that would have called `Read` on an indexed file instead receives RAG results first, without any instruction from the task briefing
- Hooks degrade gracefully when RAG or GitNexus is unreachable — the original tool call proceeds unblocked
- `workflow/templates/claude-settings.json` is committed and used as the source of truth — no manual `~/.claude/settings.json` edits required

## Dependency

None. This feature is independent of `agent-rag-v3` and can proceed in parallel.
The hook scripts will benefit from `agent-rag-v3`'s hybrid search (better results = more useful enforcement) but do not require it.
