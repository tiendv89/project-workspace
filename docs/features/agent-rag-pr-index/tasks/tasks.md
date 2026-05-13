# Tasks — agent-rag-pr-index

Feature status: `in_tdd` | Stage: `tasks` | Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | PR indexer — schema, cursor, fetcher, branch parser, poll-loop wiring | — |

## Dependency diagram

```
T1: PR indexer — schema, cursor, fetcher, branch parser, poll-loop wiring  [repo: rag-service]
  └── Can begin now — no blockers
```

---

## T1 — PR indexer — schema, cursor, fetcher, branch parser, poll-loop wiring

### Description

Implements the complete PR description indexing feature in `rag-service`. All five file changes are in the same module and tightly coupled — implementing them as a single task avoids artificial split points and unnecessary inter-task coordination overhead.

Delivers:
- `services/shared/schema.py` — adds `"pr_description"` to `VALID_SOURCE_TYPES`
- `services/indexer/branch_parser.py` — new; parses `feature/<feature_id>-T<n>` branch names into `(feature_id, task_id)` tuples
- `services/indexer/pr_indexer.py` — new; `PrIndexer` class fetches merged PRs from GitHub API newer than the file cursor, embeds, upserts to Qdrant, advances cursor atomically
- `services/indexer/indexer.py` — wires `PrIndexer` into the existing poll loop after the file-based pass; skips gracefully if `GITHUB_TOKEN` is absent
- Runtime file `services/indexer/pr_index_state.json` — not committed to git; mounted as a Docker volume for persistence; cold start (missing file) triggers full re-index (safe, upsert is idempotent)

The `rag_query` handler requires no changes — `source_types` filter passthrough already works; adding `"pr_description"` to the schema is sufficient.

### Required skills

- python-best-practices

### Subtasks

- [ ] Add `"pr_description"` to `VALID_SOURCE_TYPES` in `services/shared/schema.py`
- [ ] Implement `services/indexer/branch_parser.py` with `parse_branch(branch_name) -> (feature_id | None, task_id | None)`
- [ ] Implement `services/indexer/pr_indexer.py`:
  - [ ] Read cursor from `pr_index_state.json` (`last_indexed_merged_at`; default `None`)
  - [ ] Fetch closed PRs from GitHub API (`state=closed`, `sort=updated`, `direction=asc`), filter to `merged_at is not null`, stop paginating when `merged_at <= cursor`
  - [ ] For each new PR: build `# {title}\n\n{body}`, extract `feature_id`/`task_id` via `branch_parser`, chunk (≤1024 tokens whole; else 512-token/50-token-overlap), embed, upsert to Qdrant with full payload
  - [ ] Advance cursor atomically: write to `.tmp`, rename to `pr_index_state.json`
- [ ] Wire `PrIndexer` into `services/indexer/indexer.py` poll loop — after file-based pass, guarded by `GITHUB_TOKEN`
- [ ] Add Docker volume mount note to deployment docs / `docker-compose.yml` for `pr_index_state.json` persistence
- [ ] Write unit tests for `branch_parser.parse_branch` (happy path, no match, task-less branch)
- [ ] Write integration test: mock GitHub API + Qdrant; assert cursor advances and correct payload fields are written
- [ ] Run full test suite; confirm all tests pass before opening PR
