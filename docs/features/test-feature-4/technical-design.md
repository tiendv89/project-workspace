# Technical Design

## Feature
- Feature ID: `test-feature-4`
- Title: `Unified Search`

## Current State
The application currently has no global search capability. Each section (projects, tasks, documents, members, comments) exposes its own isolated list/filter UI. There is no shared search index, no cross-entity query surface, and no keyboard-accessible global entry point. Users must navigate to a specific section before they can filter within it.

No indexed repos or implementation symbols were found in GitNexus at design time — the workspace contains only a management repo. Concrete repo/service names are noted as open questions below.

## Constraints
- Results must be returned within 300ms for indexed data (per product spec SLA)
- Search is scoped to the current workspace only — no cross-workspace queries
- Web only for v1; no native mobile surface
- Keyword-based matching only — no semantic or NLP search
- File attachment content is excluded; filenames only
- Archived/deleted entities are excluded from results

## Options Considered

### Option A — Client-side filtering
Fetch all entities into the browser on app load and filter in-memory using a library like Fuse.js.
- Pros: Zero backend changes; instant results after initial load
- Cons: Does not scale beyond a few hundred entities; initial payload too large for real workspaces; no snippet/excerpt generation; cannot meet 300ms SLA at scale

### Option B — Database full-text search (PostgreSQL `tsvector`)
Add `tsvector` columns to each entity table and query them via a single search endpoint.
- Pros: No additional infrastructure; leverages existing DB; straightforward to implement; supports ranking via `ts_rank`
- Cons: Cross-table queries require UNION or a materialized view; snippet generation needs `ts_headline`; heavier DB load on busy workspaces

### Option C — Dedicated search service (Elasticsearch / OpenSearch)
Introduce a separate search index that mirrors entity data via event-driven sync.
- Pros: Best performance and relevance at scale; rich snippet/highlight support; horizontal scaling
- Cons: New infrastructure dependency; sync complexity; overkill for v1 scope

## Chosen Design

**Option B — PostgreSQL full-text search** is chosen for v1. It meets the 300ms SLA for typical workspace sizes, requires no new infrastructure, and is straightforward to iterate on. Option C remains the upgrade path if workspaces grow beyond PostgreSQL's practical FTS limits.

### Architecture Overview

```
Browser
  └── GlobalSearchBar (keyboard shortcut ⌘K / Ctrl+K, nav bar)
        └── GET /api/search?q=<query>&types=<filter>&from=<date>&to=<date>&assignee=<id>
              └── SearchController
                    └── SearchService
                          ├── projects   (tsvector on name, description)
                          ├── tasks      (tsvector on title, description)
                          ├── documents  (tsvector on title, content excerpt)
                          ├── members    (tsvector on full_name, email)
                          └── comments   (tsvector on body)
                    └── Returns: grouped results [{type, id, title, snippet, url}]
```

### Data Model Changes
- Add `search_vector tsvector` column to: `projects`, `tasks`, `documents`, `members`, `comments`
- Add GIN index on each `search_vector` column
- Populate via `GENERATED ALWAYS AS (to_tsvector('english', ...)) STORED` or a trigger
- Add a `search_logs` table: `(id, user_id, workspace_id, query, result_count, latency_ms, created_at)` for analytics

### API
```
GET /api/search
  Query params:
    q        — search query string (required, min 2 chars)
    types    — comma-separated entity types (optional; default: all)
    from     — ISO date lower bound on created_at (optional)
    to       — ISO date upper bound on created_at (optional)
    assignee — user ID filter for tasks (optional)
    limit    — results per type group (default: 5, max: 20)

Response:
  {
    "query": "...",
    "results": {
      "projects":  [ { id, title, snippet, url } ],
      "tasks":     [ { id, title, snippet, url } ],
      "documents": [ { id, title, snippet, url } ],
      "members":   [ { id, title, snippet, url } ],
      "comments":  [ { id, title, snippet, url } ]
    },
    "latency_ms": 42
  }
```

### Frontend Components
- `GlobalSearchBar` — floating input triggered by ⌘K/Ctrl+K; renders in a modal overlay
- `SearchResultGroup` — renders one entity-type section with title, snippet, and link
- `SearchResultItem` — single result row with highlighted match term
- Debounce input at 200ms before firing API request
- Loading skeleton shown while awaiting response

### Relevance & Ranking
- Within each entity group, results are ranked by `ts_rank_cd` (cover density)
- Groups are ordered: tasks → projects → documents → comments → members
- Top 5 results per group shown by default; "Show more" loads up to 20

## Dependency Analysis
- **Database migrations** must run before the API endpoint is deployed (search vectors must exist)
- **Frontend** depends on the API contract being finalized before component implementation begins
- No external service dependencies for v1

## Parallelization / Blocking Analysis
- **T1 — DB migrations** (add `search_vector` columns + GIN indexes + `search_logs` table): no dependencies, can start immediately
- **T2 — Search API endpoint** (`SearchController` + `SearchService`): depends on T1 (migrations must be applied)
- **T3 — Frontend `GlobalSearchBar` + result components**: can be built in parallel with T2 using a mock API response; integration blocked until T2 is complete
- **T4 — Search logging middleware**: depends on T2 (logs are written inside the search request lifecycle)

## Open Questions
- Repo/service names are unresolved — GitNexus returned no indexed repos at design time. The implementing team must confirm: backend API repo, frontend repo, and DB migration tooling before task creation.
- Confirm PostgreSQL version supports `GENERATED ALWAYS AS ... STORED` for `tsvector` (requires PG 12+); if not, triggers will be used instead.
