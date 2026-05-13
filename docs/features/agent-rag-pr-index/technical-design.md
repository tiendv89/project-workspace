# Technical Design

## Feature
- Feature ID: `agent-rag-pr-index`
- Title: RAG PR index — index merged PR titles and descriptions as a queryable source type

## Current State

The indexer (`rag-service/services/indexer/`) polls repos from `workspace.yaml` on a fixed interval. For each repo it runs `git diff` to detect changed files, chunks and embeds them, then upserts into Qdrant.

**Current `VALID_SOURCE_TYPES`** (in `services/shared/schema.py`):
```python
frozenset({"skill", "task_log", "product_spec", "technical_design", "readme", "claude_md", "doc"})
```

**Current `classify_path()`** in `source_mapper.py` — returns `None` for any path not matching the inclusion patterns; those files are skipped.

PR descriptions are not files on disk — they exist only via the GitHub REST API. The indexer has no GitHub API client today.

## Constraints

1. Merged PRs are immutable — index them once, never re-embed.
2. `GITHUB_TOKEN` is optional — absence must not crash the indexer.
3. No changes to the `rag_query` MCP tool contract.
4. PR indexing must not slow the existing file-based poll cycle — run as a separate pass.
5. Cursor state must not live in Qdrant — querying Qdrant for all indexed PR numbers on every poll is expensive at scale and loses state if the collection is rebuilt. Use a file-based cursor instead.

## Design

### Change 1 — New `source_type: "pr_description"`

**File:** `services/shared/schema.py`

```python
VALID_SOURCE_TYPES = frozenset({
    "skill", "task_log", "product_spec", "technical_design",
    "readme", "claude_md", "doc",
    "pr_description",   # ← new
})
```

### Change 2 — File-based cursor (`pr_index_state.json`)

**Runtime file:** `services/indexer/pr_index_state.json`

This file is **not committed to git**. It is operational state written and read by the running indexer process:

- **Locally:** lives on the host filesystem next to the indexer module.
- **Docker:** mount a named volume to the directory containing this file so state survives container restarts.
- **Cold start / missing file:** treated as no prior indexing — all merged PRs are fetched and indexed from scratch. This is safe because upsert is idempotent; the only cost is re-embedding on the first run.

```json
{
  "owner/repo-name": {
    "last_indexed_merged_at": "2026-05-10T12:00:00Z",
    "indexed_pr_count": 147
  }
}
```

- On first run (no entry for repo): fetch all merged PRs oldest-first, index them, write the cursor.
- On subsequent runs: fetch PRs with `merged_at > last_indexed_merged_at` only — stop paginating as soon as a page contains no newer PRs.
- After all new PRs are upserted: atomically write the updated JSON (write to a `.tmp` file, then rename) so a crash mid-write cannot corrupt the cursor.
- Each workspace deployment has its own process and filesystem, so multi-workspace isolation is free.

### Change 3 — PR indexer module

**New file:** `services/indexer/pr_indexer.py`

Responsible for fetching and indexing merged PRs for a single repo.

```python
class PrIndexer:
    def __init__(self, github_token: str, qdrant_client, embedder, workspace_id: str, state_path: str): ...

    def index_repo_prs(self, repo_full_name: str, repo_id: str) -> int:
        """Fetch merged PRs newer than cursor; embed, upsert, advance cursor. Returns count indexed."""
        ...
```

**Algorithm:**

1. **Read cursor** from `pr_index_state.json` — load `last_indexed_merged_at` for `repo_full_name`. Default to `None` if no entry exists.

2. **Fetch merged PRs from GitHub API** — `GET /repos/{owner}/{repo}/pulls?state=closed&sort=updated&direction=asc&per_page=100`. Filter to `merged_at is not null`. If cursor is set, stop paginating when `merged_at <= last_indexed_merged_at`.

3. **For each new PR (oldest first):**
   - Build document: `# {title}\n\n{body}`
   - Extract `feature_id` and `task_id` from branch name (`feature/<feature_id>-T<n>` pattern; null if no match)
   - Chunk: whole document if ≤ 1024 tokens; otherwise 512-token chunks with 50-token overlap
   - Embed via existing embedder
   - Upsert to Qdrant with payload:
     ```python
     {
       "source_type": "pr_description",
       "source_path": f"github.com/{repo_full_name}/pull/{pr_number}",
       "workspace_id": workspace_id,
       "repo_id": repo_id,
       "pr_number": pr_number,
       "feature_id": feature_id,   # null if not derivable
       "task_id": task_id,         # null if not derivable
       "pr_title": title,
       "merged_at": merged_at,
     }
     ```

4. **Advance cursor** — write updated `last_indexed_merged_at` (max `merged_at` seen) and `indexed_pr_count` to `pr_index_state.json` atomically (write to `.tmp`, rename). No git commit.

5. **Return** count of newly indexed PRs. Log at INFO level.

### Change 4 — Wire into main indexer poll loop

**File:** `services/indexer/indexer.py` (or equivalent entry point)

After the existing file-based poll for each repo, call the PR indexer if `GITHUB_TOKEN` is set:

```python
github_token = os.environ.get("GITHUB_TOKEN")
if github_token:
    state_path = os.path.join(os.path.dirname(__file__), "pr_index_state.json")
    pr_indexer = PrIndexer(github_token, qdrant_client, embedder, workspace_id, state_path)
    for repo in workspace_repos:
        count = pr_indexer.index_repo_prs(repo["github"], repo["id"])
        if count > 0:
            logger.info(f"Indexed {count} new PRs for {repo['id']}")
else:
    logger.warning("GITHUB_TOKEN not set — PR indexing skipped")
```

### Change 5 — `feature_id` / `task_id` branch name parser

**New file:** `services/indexer/branch_parser.py`

```python
import re

_PATTERN = re.compile(r"feature/(?P<feature_id>[^/]+?)(?:-T(?P<task_id>\d+))?$")

def parse_branch(branch_name: str) -> tuple[str | None, str | None]:
    """Returns (feature_id, task_id) or (None, None) if no match."""
    m = _PATTERN.search(branch_name)
    if not m:
        return None, None
    return m.group("feature_id"), m.group("task_id")
```

### Change 6 — `rag_query` filter passthrough (no-op)

The `rag_query` handler in `rag_server/server.py` already passes `source_types` as a Qdrant filter. Adding `"pr_description"` to `VALID_SOURCE_TYPES` is sufficient — no handler changes needed.

## Files changed

| Repo | File | Change |
|---|---|---|
| `rag-service` | `services/shared/schema.py` | Add `"pr_description"` to `VALID_SOURCE_TYPES` |
| `rag-service` | `services/indexer/pr_index_state.json` | Runtime file (not committed) — cursor tracking `last_indexed_merged_at` per repo; Docker volume-mount to persist across restarts |
| `rag-service` | `services/indexer/pr_indexer.py` | New — GitHub API PR fetch + embed + upsert + cursor advance |
| `rag-service` | `services/indexer/branch_parser.py` | New — branch name → `feature_id` / `task_id` |
| `rag-service` | `services/indexer/indexer.py` | Wire `PrIndexer` into poll loop |

One repo, five files. All changes are additive — no existing indexing behaviour changes.

## Parallelization

Single task. All four file changes are in the same module and are tightly coupled — implement as one task (T1).
