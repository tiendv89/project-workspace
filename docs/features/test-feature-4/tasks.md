# Task Breakdown — Unified Search (`test-feature-4`)

## Dependency Diagram

```
T1 (DB migrations)
  └── T2 (Search API)
        ├── T3 (Frontend)
        └── T4 (Logging middleware)
```

## Index

| ID | Title | Repo | Depends On | Actor |
|----|-------|------|------------|-------|
| T1 | DB migrations — add search_vector columns, GIN indexes, and search_logs table | TBD | — | agent |
| T2 | Search API endpoint — SearchController and SearchService with full-text query | TBD | T1 | agent |
| T3 | Frontend GlobalSearchBar and result components | TBD | T2 | agent |
| T4 | Search logging middleware — write query analytics to search_logs | TBD | T2 | agent |

> **Note:** Repo names are unresolved — GitNexus returned no indexed repos at design time. The implementing team must confirm backend, frontend, and DB migration repo names before execution.

---

## T1 — DB migrations — add search_vector columns, GIN indexes, and search_logs table

### Description
Add `search_vector tsvector` generated columns and GIN indexes to the five entity tables (`projects`, `tasks`, `documents`, `members`, `comments`), and create the `search_logs` analytics table. This is the prerequisite for all search functionality.

### Required skills
_(none — standard SQL migrations)_

### Subtasks
- [ ] Add `search_vector` generated column to `projects` (on `name`, `description`)
- [ ] Add `search_vector` generated column to `tasks` (on `title`, `description`)
- [ ] Add `search_vector` generated column to `documents` (on `title`, content excerpt)
- [ ] Add `search_vector` generated column to `members` (on `full_name`, `email`)
- [ ] Add `search_vector` generated column to `comments` (on `body`)
- [ ] Add GIN index on each `search_vector` column
- [ ] Create `search_logs` table: `(id, user_id, workspace_id, query, result_count, latency_ms, created_at)`
- [ ] Verify PostgreSQL version ≥ 12 for `GENERATED ALWAYS AS ... STORED`; fall back to triggers if needed
- [ ] Run and validate migrations in a staging environment

---

## T2 — Search API endpoint — SearchController and SearchService with full-text query

### Description
Implement `GET /api/search` with query params `q`, `types`, `from`, `to`, `assignee`, and `limit`. The `SearchService` executes per-entity `tsvector` queries using `ts_rank_cd` for ranking and `ts_headline` for snippets, then merges results grouped by entity type.

### Required skills
_(none — standard backend REST API)_

### Subtasks
- [ ] Create `SearchController` routing `GET /api/search`
- [ ] Implement `SearchService` with per-entity FTS queries (UNION approach)
- [ ] Apply `ts_rank_cd` ranking within each entity group
- [ ] Apply `ts_headline` for snippet generation
- [ ] Implement type, date range, and assignee filters
- [ ] Enforce workspace scoping on all queries
- [ ] Return response in the agreed grouped format with `latency_ms`
- [ ] Write unit tests covering ranking, filtering, and empty-result cases
- [ ] Confirm 300ms SLA with load test on realistic dataset

---

## T3 — Frontend GlobalSearchBar and result components

### Description
Build the `GlobalSearchBar` modal overlay (triggered by ⌘K/Ctrl+K and the nav bar icon), `SearchResultGroup`, and `SearchResultItem` components. Debounce input at 200ms, show loading skeleton, highlight matched terms, and support "Show more" per group.

### Required skills
_(none — standard frontend component work)_

### Subtasks
- [ ] Implement `GlobalSearchBar` modal triggered by ⌘K/Ctrl+K and nav bar button
- [ ] Implement 200ms debounce before firing API request
- [ ] Implement `SearchResultGroup` — entity-type section with label and result list
- [ ] Implement `SearchResultItem` — result row with highlighted match, snippet, and link
- [ ] Show loading skeleton while awaiting API response
- [ ] Implement "Show more" expanding up to 20 results per group
- [ ] Group ordering: tasks → projects → documents → comments → members
- [ ] Add unread/active keyboard navigation (arrow keys + Enter)
- [ ] Write component tests for empty state, loading state, and result rendering

---

## T4 — Search logging middleware — write query analytics to search_logs

### Description
Add middleware (or a hook inside `SearchService`) that writes each search request to the `search_logs` table: user ID, workspace ID, query string, result count, and measured latency. This enables future analytics on search quality and usage patterns.

### Required skills
_(none — standard backend middleware)_

### Subtasks
- [ ] Add logging hook to `SearchService` (post-query, non-blocking)
- [ ] Write `(user_id, workspace_id, query, result_count, latency_ms, created_at)` to `search_logs`
- [ ] Ensure logging errors do not propagate to the search response (fire-and-forget or try/catch)
- [ ] Write unit test verifying a log row is created on each search request
