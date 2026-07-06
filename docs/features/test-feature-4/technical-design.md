# Technical Design

## Feature
- Feature ID: `test-feature-4`
- Title: `Unified Search`

## Current State
The application currently provides siloed, section-level search — users must search separately inside each section (projects, tasks, members, documents) with no cross-section discovery. There is no global search bar, no unified index, and no keyboard-shortcut entry point. The underlying data store and search infrastructure are not indexed in GitNexus, so concrete table and component names are recorded as open questions below.

## Constraints
- Results must be returned within 300ms for queries on indexed data
- Search is scoped to the current workspace only (no cross-workspace support)
- v1 is keyword-based only — no semantic or natural-language parsing
- Indexed entity types: projects, tasks, documents, members, comments (filenames only for attachments; no full-text inside files)
- Archived and deleted entities are excluded from search
- No saved/pinned searches or search history in v1

## Options Considered

### Option A — Postgres Full-Text Search (FTS) with tsvector/tsquery
Extend the existing Postgres database with `tsvector` columns on each entity table. A background job keeps the vectors updated via triggers or periodic re-indexing. The API performs `ts_query` queries with `plainto_tsquery` and merges per-type results.

- Pros:
  - No new infrastructure; reuses the existing database
  - ACID-compliant; no sync lag between write and search
  - Postgres FTS easily achieves sub-300ms at moderate data volumes
  - Grouped and ranked results with `ts_rank` built-in
- Cons:
  - Ranking quality is lower than a dedicated search engine
  - Scaling beyond millions of rows requires careful indexing
  - Multi-language support requires additional configuration

### Option B — Dedicated Search Engine (Elasticsearch / Meilisearch)
Run a dedicated search engine alongside the database. Entity writes are dual-written (or streamed via CDC) into the search engine's index. The API queries the search engine directly.

- Pros:
  - Superior ranking and full-text capabilities
  - Scales independently of the primary database
  - Supports rich filter facets natively
- Cons:
  - Introduces new infrastructure to operate and maintain
  - Sync lag between DB write and index update introduces eventual consistency
  - Significantly more complex to deploy, monitor, and keep in sync
  - Overkill for v1 keyword search requirements

## Chosen Design

**Option A — Postgres Full-Text Search** is selected for v1.

The performance requirement (300ms) and keyword-only scope are well within Postgres FTS capability without additional infrastructure. The design avoids dual-write complexity and keeps the system operationally simple.

### Backend: Search API Endpoint

**`GET /api/search?q=<query>&types=<csv>&date_from=<ISO>&date_to=<ISO>&assignee=<userId>`**

- `q` — keyword query string (required)
- `types` — optional comma-separated filter: `projects,tasks,documents,members,comments`
- `date_from` / `date_to` — optional ISO-8601 date range filter (applied to `created_at` or `updated_at`)
- `assignee` — optional user ID filter (applicable to tasks and projects)

Response shape:
```json
{
  "results": {
    "projects":  [{ "id", "title", "snippet", "url", "updated_at" }],
    "tasks":     [{ "id", "title", "snippet", "assignee", "url", "updated_at" }],
    "documents": [{ "id", "title", "snippet", "url", "updated_at" }],
    "members":   [{ "id", "name", "avatar_url", "url" }],
    "comments":  [{ "id", "snippet", "entity_url", "updated_at" }]
  },
  "total": <int>,
  "query_ms": <int>
}
```

### Database: tsvector Columns and Indexes

Each searchable entity table gains a `search_vector tsvector` column populated by a `BEFORE INSERT OR UPDATE` trigger:

```sql
-- Example: tasks table
ALTER TABLE tasks ADD COLUMN search_vector tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))
  ) STORED;

CREATE INDEX tasks_search_vector_idx ON tasks USING GIN (search_vector);
```

Similar triggers are added to `projects`, `documents`, `members` (name/email fields), and `comments`. Archived and deleted rows are filtered with a `WHERE deleted_at IS NULL AND archived_at IS NULL` clause in queries.

### Frontend: Global Search Bar Component

- A persistent `GlobalSearchBar` component is mounted in the top navigation bar on all pages.
- Keyboard shortcut `Cmd+K` / `Ctrl+K` opens a floating search modal.
- The modal shows a text input with debounced query dispatch (250ms debounce to stay under the 300ms budget).
- Results are rendered grouped by entity type with a relevance rank badge.
- Each result shows an entity icon, title, and a snippet (highlighted match excerpt).
- Filter chips below the input allow narrowing by type, date range, and assignee.
- Clicking a result navigates to the entity's detail page and closes the modal.

### Snippet Generation

- Snippets are generated using Postgres `ts_headline()` with `MaxWords=15, MinWords=5`.
- Frontend truncates to 120 characters if the snippet exceeds that length.

### Performance Strategy

- GIN indexes on `search_vector` columns provide sub-100ms queries at typical SaaS data volumes.
- Debounce on the frontend reduces round-trips.
- A 5-second server-side query timeout prevents slow queries from blocking connections.
- Result set is capped at 10 items per entity type (50 total max).

## Dependency Analysis

> ⚠️ **Open questions — GitNexus returned no indexed repos for this workspace.** The table names, file paths, API router locations, and frontend component tree below are inferred from the product spec and common project conventions. A human must confirm or correct these before implementation begins.

| Dependency | Assumption | Status |
|---|---|---|
| Primary database | Postgres (inferred from typical stack) | ❓ Unconfirmed |
| Entity tables | `tasks`, `projects`, `documents`, `members`, `comments` | ❓ Unconfirmed |
| API router | REST; search endpoint added under `/api/search` | ❓ Unconfirmed |
| Frontend framework | React (inferred) | ❓ Unconfirmed |
| Nav bar component path | Unknown — needs GitNexus lookup | ❓ Unconfirmed |
| Auth / workspace-scoping middleware | Assumed to exist; search queries must pass `workspace_id` from session | ❓ Unconfirmed |

## Parallelization / Blocking Analysis

The work splits into three parallel tracks after the DB migrations land:

```
T1: DB migrations (tsvector columns + GIN indexes)
  └─ T2: Backend search API endpoint        [depends on T1]
  └─ T3: Frontend GlobalSearchBar component [depends on T1 only for schema contract]

T2 + T3 can proceed in parallel once T1 is merged.

T4: Integration / E2E tests                [depends on T2 + T3]
```

- **T1** is the critical-path blocker; all other tasks depend on the schema being stable.
- **T2** and **T3** can be developed in parallel against the T1 contract (API response shape and DB columns).
- **T4** depends on both T2 and T3 being merged.
