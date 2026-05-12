# Product Specification

## Feature
- Feature ID: `agent-rag-pr-index`
- Title: RAG PR index — index merged PR titles and descriptions as a queryable source type

## Problem

Every task produces a merged PR whose description contains delivery-time knowledge that exists nowhere else in the indexed corpus:

- Why a function was refactored or deleted
- What tradeoffs were made during implementation
- Which tests passed or failed and why
- Deviations from the technical design and the reasoning behind them
- What the next agent should know before touching related code

This knowledge is written at the moment of highest context — when the implementing agent has just finished — and is currently lost the moment the session ends. It is not in product specs (those describe intent, not delivery). It is not in technical designs (those describe the plan, not what actually happened). It is not in task logs (those record actions, not reasoning).

Agents starting related tasks re-discover this context through grep, file reads, and cold exploration. They make the same mistakes, miss the same tradeoffs, and duplicate the same discovery work.

`agent-rag-v3` ruled out indexing PR review comments as "low value given current PR review workflow." PR **descriptions** are a different category — they are authored summaries, not conversational threads, and they are the closest thing to a commit message for a multi-file task.

## Goals

1. **Index merged PR descriptions** — for every repo in `workspace.yaml`, the indexer fetches merged PRs via the GitHub REST API and indexes title + body as `source_type: "pr_description"`.

2. **Agents can answer delivery questions** — "why was `runOneCycle` refactored?", "what did T3 of `agent-runtime-redesign` actually change?", "were there any deviations in the auth middleware task?" become answerable via `rag_query`.

3. **Stable, incremental indexing** — merged PRs are immutable. The indexer tracks which PR numbers have been indexed per repo and only fetches new ones. No re-embedding on every poll cycle.

4. **Feature and task linkage** — PR descriptions are tagged with `feature_id` and `task_id` derived from the branch name (`feature/<feature_id>-T<n>`), so `rag_query` with `source_types: ["pr_description"]` can be filtered by feature scope.

5. **No agent-facing API changes** — `rag_query` tool signature is unchanged. Agents query PR context the same way they query any other source type.

## Non-goals

- Not indexing PR review comments or inline code comments — conversational, low signal-to-noise
- Not indexing open PRs — they change frequently; merged PRs are stable and authoritative
- Not indexing PRs from repos outside `workspace.yaml`
- Not requiring `GITHUB_TOKEN` to be set — if absent, PR indexing is skipped gracefully (non-fatal)

## Dependency

- `agent-rag-v2` must be deployed (provides the Qdrant collection and indexer infrastructure this feature extends)
- Independent of `agent-rag-v3` — does not require hybrid search or event-driven trigger; can ship before v3

## Success criteria

- `rag_query("why was runOneCycle refactored", workspace_id="workspace", source_types=["pr_description"])` returns the PR #140 description in the top 3 results
- `rag_query("T3 agent-runtime-redesign implementation", workspace_id="workspace", source_types=["pr_description"])` returns the relevant PR description
- Indexer only fetches PRs not yet indexed on each poll cycle (idempotent, no re-embedding)
- If `GITHUB_TOKEN` is absent, indexer logs a warning and skips PR indexing — no crash
