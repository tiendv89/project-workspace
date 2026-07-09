# Tasks — storage-service

Feature status: `in_handoff` | Stage: `tasks` | Machine state lives in `tasks/T<n>.yaml`.

`storage-service` is now created and indexed in GitNexus (bootstrapped by T1).
All 18 tasks from the approved technical design are now registered below —
this supersedes the earlier partial breakdown that deferred T5–T12, T14, T17,
T18 pending the repo's existence.

**Amendment (2026-07-09):** T1–T18 are done (7 implementation PRs open,
awaiting merge). T19–T23 (Wave 6) are appended below per the product-spec/
technical-design Amendment sections — GCS→MinIO (T19), `workflow-mcp`
document tools replacing T13's direct-call approach (T20/T21), and
version-history labeling (T22/T23). No existing task (T1–T18) is modified or
reopened.

## Index

| ID | Wave | Title | Repo | Depends on | Actor |
|---|---|---|---|---|---|
| T1 | 0 | Bootstrap `storage-service` repo + register in `workspace.yaml` | storage-service | — | agent |
| T2 | 1 | `POST /internal/index` webhook endpoint | rag-service | — | agent |
| T3 | 1 | Folder-tree sidebar component (mocked API) | digital-factory-ui | — | agent |
| T4 | 1 | Add `/bff/storage-service/*` upstream prefix | workflow-bff | T1 | agent |
| T5 | 1 | Provision Hocuspocus WebSocket public ingress/TLS | storage-service | T1 | agent |
| T6 | 2 | `internal/document` module (CRUD, doc_version, markdown import, folder-tree read API) | storage-service | T1 | agent |
| T7 | 2 | Node Hocuspocus sidecar (onLoadDocument/onStoreDocument/onAuthenticate) | storage-service | T1 | agent |
| T8 | 2 | Sync-token mint endpoint | storage-service | T1 | agent |
| T9 | 3 | Tiptap editor component wired to Hocuspocus + document/history APIs | digital-factory-ui | T3, T4, T5, T6, T7, T8 | agent |
| T10 | 3 | RAG webhook wiring in `onStoreDocument` | storage-service | T2, T7 | agent |
| T11 | 3 | Version-history timeline API (list/diff/restore) | storage-service | T6 | agent |
| T12 | 3 | Version-history panel UI | digital-factory-ui | T3, T11 | agent |
| T13 | 4 | `init-feature` Step 0 wiring (go ⇒ storage-service document create) | agent-workflow | T1 | agent |
| T14 | 4 | Migration tool (bulk GitHub import) | storage-service | T6 | agent |
| T15 | 4 | `hermes-agent` owner guard on the four document tools | hermes-agent | T1 | agent |
| T16 | 4 | Guard: reject writes to a migrated feature's git document paths | workflow-backend | T1 | agent |
| T17 | 5 | Admin API routes (usage, object browser, empty-trash, orphan cleanup, migration status) | storage-service | T6, T14 | agent |
| T18 | 5 | `/admin/storage` page | digital-factory-ui | T3, T17 | agent |
| T19 | 6 | Migrate blob backend from GCS to MinIO | storage-service | T1 | agent |
| T20 | 6 | `workflow-mcp` document read/write MCP tools | workflow-mcp | T4, T6 | agent |
| T21 | 6 | Rework `init-feature`'s `go` branch to call T20's tools | agent-workflow | T20 | agent |
| T22 | 6 | `doc_version` label/pin column + set-label endpoint | storage-service | T11 | agent |
| T23 | 6 | Label/pin a version in the history panel | digital-factory-ui | T12, T22 | agent |

**Implementation-gate note for T13/T15/T16:** these are functionally
dependent on T6 (real storage-service document endpoints) even though their
declared `depends_on` is only T1 (repo existence). This is now made fully
explicit in the dependency graph below — treat T6 as a hard implementation
gate for these three even though the earlier partial breakdown only encoded
T1.

## Dependency diagram

```
Wave 0 (bootstrap):
  T1  storage-service  Bootstrap storage-service repo + register in workspace.yaml

Wave 1 (parallel):
  T2  rag-service        POST /internal/index webhook endpoint
  T3  digital-factory-ui Folder-tree sidebar (mocked API)
  T4  workflow-bff       /bff/storage-service/* upstream prefix        [dep: T1]
  T5  storage-service    Hocuspocus WS public ingress/TLS              [dep: T1]

Wave 2 (dep: T1):
  T6  storage-service    internal/document module
  T7  storage-service    Node Hocuspocus sidecar
  T8  storage-service    Sync-token mint endpoint

Wave 3:
  T9  digital-factory-ui Tiptap editor + Hocuspocus + document/history APIs   [dep: T3,T4,T5,T6,T7,T8]
  T10 storage-service    RAG webhook wiring in onStoreDocument                 [dep: T2,T7]
  T11 storage-service    Version-history timeline API                        [dep: T6]
  T12 digital-factory-ui Version-history panel UI                            [dep: T3,T11]

Wave 4:
  T13 agent-workflow     init-feature Step 0 wiring                          [dep: T1; functional gate: T6]
  T14 storage-service    Migration tool (bulk GitHub import)                 [dep: T6]
  T15 hermes-agent       Owner guard on the four document tools              [dep: T1; functional gate: T6]
  T16 workflow-backend   Guard: reject writes to migrated feature's git paths [dep: T1; functional gate: T14]

Wave 5:
  T17 storage-service    Admin API routes                                    [dep: T6,T14]
  T18 digital-factory-ui /admin/storage page                                 [dep: T3,T17]

Wave 6 (amendment, 2026-07-09 — appended after T1-T18 shipped):
  T19 storage-service    Migrate blob backend from GCS to MinIO              [dep: T1]
  T20 workflow-mcp       Document read/write MCP tools                      [dep: T4,T6]
  T21 agent-workflow     Rework init-feature's go branch onto T20's tools    [dep: T20]
  T22 storage-service    doc_version label/pin column + set-label endpoint  [dep: T11]
  T23 digital-factory-ui Label/pin a version in the history panel           [dep: T12,T22]
```

---

## T1 — Bootstrap `storage-service` repo + register in `workspace.yaml`

### Description

Creates the new `storage-service` GitHub repo and scaffolds it per the
approved technical design (§1): a Go API skeleton (`internal/blob`,
`internal/document` package stubs, Gin, pgx, GCS client dependency, Dockerfile)
and a Node `sync/` Hocuspocus sidecar skeleton (package.json, Dockerfile). Adds
`storage-service` as a new `repos[]` entry in `workspace.yaml` (management
repo) so GitNexus indexes it. **Status: done** — the repo now exists and is
indexed in GitNexus; this task's remaining subtasks (if any) should be closed
out per its own task YAML log.

### Required skills

- go-best-practices

### Subtasks

- [x] Create the `storage-service` GitHub repo
- [ ] Scaffold Go API: Gin app skeleton, `internal/blob`/`internal/document`
      empty package stubs, pgx config, GCS client dependency, health endpoint,
      Dockerfile
- [ ] Scaffold Node `sync/` Hocuspocus sidecar: package.json, minimal
      Hocuspocus server skeleton, Dockerfile
- [x] Add `storage-service` to `workspace.yaml`'s `repos[]`
- [x] GitNexus has indexed the new repo (confirmed)

---

## T2 — `POST /internal/index` webhook endpoint

### Description

Adds a new internal-only endpoint to `rag-service` that accepts
`{workspace_id, feature_id, document_kind, content}` and re-embeds/upserts the
content into Qdrant, reusing the existing `chunker.py` chunking strategy
(`product_spec`/`technical_design` get the 512-token sliding window; the same
strategy applies to `tasks`/`handoff` content). Guarded by a shared internal
token, mirroring the existing `GITHUB_TOKEN`-gated internal pattern already
used for `pr_indexer`. Does **not** modify `git_watcher.py` or `pr_indexer.py`
— this is purely additive, and `ts`-backend features continue to be indexed by
the existing git-triggered path unchanged.

### Required skills

- python-best-practices

### Subtasks

- [ ] New `POST /internal/index` route, guarded by a shared internal token env var
- [ ] Reuse `chunker.chunk_document` for the incoming content, tagged with the
      appropriate `source_type`
- [ ] Upsert to Qdrant with `workspace_id` isolation (same pattern as the
      existing indexer)
- [ ] Unit tests: happy path, missing/invalid token rejection, unknown
      `document_kind`

---

## T3 — Folder-tree sidebar component (mocked API)

### Description

Builds the sidebar tree UI component in `digital-factory-ui` showing
`workspace → feature → document` (no sub-pages — a document is always a leaf).
Reuses HeroUI's existing list/tree primitives (no new dependency). Built
against a mocked document-list API response shape so it can proceed in
parallel with the backend; wired to the real `storage-service` folder-tree
read endpoint once T6 ships (follow-up wiring happens in T9/T18, not this
task).

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Sidebar tree component: workspace → feature → document, HeroUI primitives
- [ ] Mocked data layer matching the folder-tree read API's expected response
      shape (`GET /api/workspaces/:wid/features/:fid/documents`)
- [ ] Empty-state and loading-state handling
- [ ] Component tests

---

## T4 — Add `/bff/storage-service/*` upstream prefix

### Description

Config-only change to `workflow-bff`'s existing longest-prefix reverse proxy
(`configs/config.yaml`'s `bff.upstreams`), adding `/bff/storage-service/*`
alongside the existing `/bff/workflow-backend`, `/bff/hermes-agent`,
`/bff/user-service` entries. No per-route registration or new proxy code is
needed. Identity header injection (`X-User-Id`/`X-Org-Id`/
`X-Accessible-Org-Ids`) applies automatically to the new prefix, same as every
other upstream.

### Required skills

- go-best-practices

### Subtasks

- [ ] Add `/bff/storage-service/*` to `bff.upstreams` config
- [ ] Confirm identity-header injection applies to the new prefix (test only,
      no code change expected)
- [ ] Integration test: a request through `/bff/storage-service/*` reaches a
      stub upstream with identity headers present

---

## T5 — Provision Hocuspocus WebSocket public ingress/TLS

### Description

Provisions the Hocuspocus sidecar's own public WebSocket ingress — deliberately
**not** routed through `workflow-bff` (which rejects WebSocket upgrades with
HTTP 501). Sets up TLS termination and a WS-origin/CORS allowlist for the
sidecar's public endpoint. Independent of T4's BFF change; both are
prerequisites for T9's end-to-end Tiptap↔Hocuspocus connection.

### Required skills

- go-best-practices

### Subtasks

- [ ] Provision public ingress + TLS termination for the Hocuspocus sidecar's
      WebSocket endpoint
- [ ] Configure WS-origin/CORS allowlist (frontend origin only)
- [ ] Document the ingress endpoint URL/config for T7/T9 to consume
- [ ] Smoke test: WS handshake succeeds against a stub echo server on the
      provisioned ingress

---

## T6 — `internal/document` module (CRUD, doc_version, markdown import, folder-tree read API)

### Description

Builds `storage-service`'s document domain on top of T1's blob layer:
- `document` CRUD (`id, workspace_id, feature_id, kind` [`product_spec|
  technical_design|tasks|handoff`], `slug, folder_id NULL, current_version_id,
  created_at, deleted_at`).
- `doc_version` table + writes (`id, document_id, snapshot_ref, parent_version_id,
  author, created_at, source` [`edit|import|migration`]).
- Folder-tree read API: `GET /api/workspaces/:wid/features/:fid/documents` —
  flat list scoped by `feature_id` (no `folder` table in v1).
- Markdown import endpoint: `POST /api/documents/import` — parses `.md` →
  ProseMirror JSON → seeds a `Y.Doc` → writes snapshot #1 as `doc_version`
  `source: "import"`.
- Soft-delete (`DELETE /api/documents/:id` → `deleted_at`), trash list
  (`GET /api/workspaces/:wid/trash`), and restore (`POST /api/.../restore`).

This is the second foundation task — T9, T11, T13, T14, T15, T17 all
functionally depend on it (only T14/T11/T9's `depends_on` encode it directly;
T13/T15 depend on it as an implementation gate — see the Index note above).

### Required skills

- go-best-practices

### Subtasks

- [ ] `document` table CRUD (create, read, list-by-feature, soft-delete, restore)
- [ ] `doc_version` table + write path (snapshot_ref, parent_version_id, author,
      source)
- [ ] Folder-tree read API (`GET /api/workspaces/:wid/features/:fid/documents`)
- [ ] Markdown import endpoint (`.md` → ProseMirror JSON → seed `Y.Doc` →
      snapshot #1)
- [ ] Trash list + restore endpoints
- [ ] Unit + integration tests for all of the above

---

## T7 — Node Hocuspocus sidecar (onLoadDocument/onStoreDocument/onAuthenticate)

### Description

Stands up the `sync/` Node deployable (own `Dockerfile`) running Hocuspocus:
- `onAuthenticate`: verifies the short-lived HMAC-signed sync token (minted by
  T8) locally — no per-connection network call.
- `onLoadDocument`: reads the current `doc_version.snapshot_ref` blob from GCS
  via the Go API's internal blob-read (private network, `STORAGE_INTERNAL_TOKEN`
  from T1), decodes into a `Y.Doc`.
- `onStoreDocument`: on debounce, calls `Y.snapshot(ydoc)` →
  `Y.encodeSnapshot()`, POSTs the bytes to the Go API's internal blob-write,
  inserts a `doc_version` row (via T6's write path).
- Sets `ydoc.gc = false` at document creation.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Node service scaffold refinement (builds on T1's skeleton)
- [ ] `onAuthenticate` — verify sync token signature/expiry/claims (no network
      call)
- [ ] `onLoadDocument` — fetch snapshot blob via internal blob-read, decode to
      `Y.Doc`
- [ ] `onStoreDocument` — snapshot, encode, write blob + `doc_version` row via
      internal endpoints
- [ ] `ydoc.gc = false` set at document creation
- [ ] Debounce logic (N seconds after last edit / on publish)
- [ ] Unit tests (mocked Go API internal endpoints)

---

## T8 — Sync-token mint endpoint

### Description

Adds `POST /bff/storage-service/api/documents/:id/sync-token` to the Go API —
a normal BFF-authenticated REST call (identity + ACL checked exactly like
every other `storage-service` route) that mints a short-TTL (~60s)
HMAC-signed token carrying `{workspace_id, document_id, user_id, exp}`, signed
with `STORAGE_SYNC_TOKEN_SECRET` (from T1). The browser's Tiptap collaboration
provider calls this before opening the Hocuspocus WebSocket, and again on
token expiry mid-session.

### Required skills

- go-best-practices

### Subtasks

- [ ] `POST .../documents/:id/sync-token` endpoint — identity/ACL check reuses
      T1's auth middleware
- [ ] HMAC-sign the token payload with `STORAGE_SYNC_TOKEN_SECRET`
- [ ] Unit tests: valid token issuance, ACL rejection for a document outside
      the caller's workspace, token expiry field correctness

---

## T9 — Tiptap editor component wired to Hocuspocus + document/history APIs

### Description

Replaces `FeatureIDEDocsPanel`'s content pane with a Tiptap
(ProseMirror + Yjs) editor for `storage-service`-backed documents only — `ts`
features keep the existing markdown panel unchanged. Wires:
- The Tiptap collaboration provider to the Hocuspocus WebSocket (via T5's
  ingress), authenticated with a sync token from T8, refreshed on expiry.
- Document CRUD/history reads to `storage-service`'s Go API (via T4's BFF
  prefix).
- Markdown export (Tiptap's markdown extension) as the `.md`-download escape
  hatch.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Tiptap editor component (ProseMirror + Yjs) replacing the content pane
      for storage-service-backed documents
- [ ] Hocuspocus collaboration provider wiring, sync-token fetch + refresh on
      expiry
- [ ] Document CRUD/history API integration via `/bff/storage-service/*`
- [ ] Markdown export (download-as-.md) action
- [ ] Concurrent-edit test: two sessions editing the same document, verify
      both edits merge (no conflict error, no last-write-wins)
- [ ] Component/integration tests

---

## T10 — RAG webhook wiring in `onStoreDocument`

### Description

Extends T7's `onStoreDocument` hook to call T2's `POST /internal/index`
endpoint after writing each snapshot, passing `{workspace_id, feature_id,
document_kind, content}`. Debounced at the same point the snapshot is taken
(not on every keystroke).

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Call `rag-service`'s `POST /internal/index` from `onStoreDocument` after
      snapshot write
- [ ] Pass the shared internal token (from T2) on the call
- [ ] Error handling: RAG webhook failure must not block or roll back the
      snapshot write itself (log and continue)
- [ ] Integration test (mocked rag-service endpoint)

---

## T11 — Version-history timeline API (list/diff/restore)

### Description

Adds read/action endpoints on top of T6's `doc_version` table:
- `GET /api/documents/:id/versions` — list timeline (linear, single-parent).
- `GET /api/documents/:id/versions/diff?a=&b=` — decode both snapshots to
  ProseMirror JSON, recursive structural diff.
- `POST /api/documents/:id/versions/:version_id/restore` — decode the
  snapshot, `Y.createDocFromSnapshot`, swap in as the live state (broadcast to
  connected Hocuspocus clients via T7).

### Required skills

- go-best-practices

### Subtasks

- [ ] List-versions endpoint (timeline, newest-first)
- [ ] Diff endpoint — decode two snapshots, structural diff, return change set
- [ ] Restore endpoint — decode snapshot, swap in as live state, notify T7's
      sidecar to broadcast the update to connected clients
- [ ] Unit tests: list, diff (added/removed/changed content), restore
      round-trip

---

## T12 — Version-history panel UI

### Description

Adds a history panel in `digital-factory-ui` (alongside T3's folder tree)
showing a document's version timeline, a diff view between two selected
versions, and a restore action — consuming T11's endpoints via T4's BFF
prefix.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Timeline list component (version, author, timestamp)
- [ ] Diff view (two-version comparison, highlight changes)
- [ ] Restore action with confirmation
- [ ] Component tests

---

## T13 — `init-feature` Step 0 wiring (go ⇒ storage-service document create)

### Description

Extends the existing Step 0 `go`/`ts` question in the `init-feature` skill
(`agent-workflow` repo) — no second axis. For `go`: calls `storage-service`'s
document-create endpoint (T6) to seed `product-spec.md`, `technical-design.md`,
`tasks.md`, and `handoffs/` from the existing templates
(`<WORKSPACE_ROOT>/workflow/templates/feature/`) as `storage-service`
documents instead of writing local git files. For `ts`: unchanged (current
git-file behavior). Same hard-stop discipline as today — if the choice isn't
explicit, ask again, don't guess.

**Implementation gate:** functionally depends on T6 shipping a real
document-create endpoint — do not enable the `go` branch in production until
T6 is done, even though `depends_on` only lists T1.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Extend Step 0's `go`/`ts` fork: `go` branch calls storage-service's
      document-create endpoint for each of the four narrative documents
- [ ] Seed content from the existing templates on creation
- [ ] `ts` branch behavior verified unchanged (regression check)
- [ ] Tests: `go` path creates storage-service documents (mocked API), `ts`
      path creates git files as before

---

## T14 — Migration tool (bulk GitHub import)

### Description

One-time, admin-triggered tool reusing T6's `.md`-import path in bulk. Reads
`product-spec.md`/`technical-design.md`/`tasks.md`/`handoffs/*.md` bytes
directly via the GitHub Contents API (a scoped, throwaway client — explicitly
not built on `workspace-github-adapter`). Idempotent per feature+slug (checks
for an existing `document` row before creating). Seeds `doc_version` #1 with
`source: "migration"` and a note recording the source commit SHA. Fires T2's
RAG webhook per migrated doc.

### Required skills

- go-best-practices

### Subtasks

- [ ] Direct GitHub Contents API client (read-only, scoped to this tool, no
      `workspace-github-adapter` dependency)
- [ ] Per-feature migration action: idempotency check, import via T6's path,
      seed `doc_version` #1 with `source: "migration"` + source SHA
- [ ] Bulk migration action (iterate all git-backed features)
- [ ] Fire RAG webhook per migrated doc
- [ ] Migration-status tracking (git-only / migrated / failed) exposed for T17
- [ ] Unit tests: idempotent re-run, partial-failure handling, status tracking

---

## T15 — `hermes-agent` owner guard on the four document tools

### Description

Extends the existing `_owner_guard_ts_only` pattern
(`plugins/tools/artifacts.py:264-283`) to `read_document`,
`write_product_spec`, `write_technical_design`, and `edit_document`. For a
`go`-owned feature, each tool proxies to `storage-service`'s document
read/write endpoints (T6) using the new `STORAGE_SERVICE_TOKEN` (from T1)
instead of committing to git. For `ts`-owned (or absent-owner, which defaults
to `ts`) features, behavior is completely unchanged — no modification to
`document_repo.py`'s git-commit machinery.

**Implementation gate:** functionally depends on T6 shipping real document
read/write endpoints — do not enable the `go`-owned proxy path in production
until T6 is done, even though `depends_on` only lists T1.

### Required skills

- python-best-practices

### Subtasks

- [ ] Add owner-check to `read_document`/`write_product_spec`/
      `write_technical_design`/`edit_document`, following the existing
      `_owner_guard_ts_only` shape
- [ ] `go`-owned path: proxy to storage-service's document read/write
      endpoints using `STORAGE_SERVICE_TOKEN`
- [ ] `ts`-owned / absent-owner path: unchanged git-commit behavior (regression
      check)
- [ ] Unit tests: go-owned proxies to storage-service (mocked), ts-owned/absent
      still commits to git, no stray git file created for a go-owned feature

---

## T16 — Guard: reject writes to a migrated feature's git document paths

### Description

Small guard addition to `workflow-backend`'s `internal/handler/document.go` —
after T14's migration tool marks a feature's documents as migrated, writes to
that feature's git document paths are rejected with 403 (the git copy is
frozen/read-only per the approved spec's Non-goals). This is not a rewrite of
`document.go` — the existing read/view path is unchanged; only a write-path
guard is added, keyed off T14's migration-status tracking.

**Implementation gate:** functionally depends on T14 shipping a real
migration-status endpoint — do not enable the guard in production until T14
is done, even though `depends_on` only lists T1.

### Required skills

- go-best-practices

### Subtasks

- [ ] Add a migration-status check (calling storage-service's migration-status
      read, or a cached flag) before any write to a feature's git document path
- [ ] Return 403 with a clear message when the feature is migrated
- [ ] Read/view path unchanged (regression check)
- [ ] Unit tests: write rejected for a migrated feature, write allowed for a
      non-migrated feature

---

## T17 — Admin API routes (usage, object browser, empty-trash, orphan cleanup, migration status)

### Description

Adds `/api/admin/storage/...` routes on `storage-service`, guarded by a
service-to-service platform-role check against `user-service` (using the
`X-User-Id` from T1's trusted header — same shape as `user-service`'s existing
internal role-check surface). Surfaces: usage/quota per workspace (bytes +
object count), object browser (list/search/filter, delete-to-trash), an
empty-trash action (immediate permanent purge, bypassing retention), orphan
cleanup (unattached blobs older than N days), and migration status per feature
(from T14, with retry/trigger inline). Also implements the scheduled purge job
(hard-deletes GCS objects + rows where `deleted_at < now() - retention_window`,
default 30 days).

### Required skills

- go-best-practices

### Subtasks

- [ ] Service-to-service platform-role check against `user-service`
- [ ] Usage/quota endpoint (bytes + object count per workspace)
- [ ] Object browser endpoint (list/search/filter, scoped by workspace)
- [ ] Empty-trash endpoint (immediate permanent purge)
- [ ] Orphan-cleanup endpoint (sweep unattached blobs older than N days)
- [ ] Migration-status endpoint (surfacing T14's tracking, retry/trigger action)
- [ ] Scheduled purge job (retention-window-based hard delete)
- [ ] Unit tests for all endpoints + the purge job's retention-window logic

---

## T18 — `/admin/storage` page

### Description

Adds `/admin/storage` to `digital-factory-ui`, sibling to `/admin/members`
under the existing `AdminLayout`/`isPlatformAdmin` guard — no new shell/auth.
Consumes T17's admin API routes via T4's BFF prefix. Surfaces usage/quota,
object browser with delete-to-trash, empty-trash action, orphan cleanup, and
migration status (with retry/trigger inline), reusing T3's tree/list UI
patterns where applicable.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] `/admin/storage` page under the existing `AdminLayout` guard
- [ ] Usage/quota overview view
- [ ] Object browser view (list/search/filter, delete-to-trash action)
- [ ] Empty-trash action (with confirmation)
- [ ] Orphan-cleanup action
- [ ] Migration-status view (retry/trigger inline)
- [ ] Component tests

---

## T19 — Migrate blob backend from GCS to MinIO

### Description

Amendment (2026-07-09, technical design §Amendment / point 1). Swaps
`internal/blob/store.go`'s GCS SDK calls for MinIO, using
**`github.com/minio/minio-go/v7`** — required, not the AWS S3 SDK or another
S3-compatible client, per explicit human direction. Confirmed via code survey
of the merged `feature/storage-service` branch: `blob.Store` is the single
chokepoint (only file besides `cmd/api/main.go`'s client construction that
imports `cloud.google.com/go/storage`); the three consumer interfaces
(`document.BlobStore`, `migration.BlobUploader`, `admin.GCSDeleter`) are
unchanged in shape, so `internal/document`, `internal/migration`,
`internal/admin` need no code changes. No presigned URLs exist anywhere
today — every blob read/write already goes through the Go API's own internal
HTTP endpoints, so there is no client-visible signing scheme to port.

Also renames the `blob.gcs_path` column to `blob.object_key` (new migration;
safe now — no production data exists yet, T1–T18's impl PRs are still open)
and updates the `"gcs_path"` JSON field in `internal/admin/handler.go` and
all references in `internal/admin/store.go`. Enables MinIO bucket versioning
on the blob bucket at provisioning time — defense-in-depth underneath the
app's own `doc_version` history (T6/T11), not a replacement for it; no API
shape changes as a result.

Local dev: adds a MinIO (AIStor) service to `docker-compose.yml`, with the
AIStor license file bind-mounted (`-v $HOME/minio/minio.license:/minio.license
--license /minio.license`, per the AIStor container install docs) and
`MINIO_ENDPOINT`/`MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY`/`MINIO_BUCKET`/
`MINIO_USE_SSL`/`MINIO_LICENSE_PATH` replacing `GCS_BUCKET`/
`GOOGLE_APPLICATION_CREDENTIALS` in `.env.template`. The human provides the
AIStor license — resolve via `resolve-project-env`; if missing, ask the human
rather than guessing or falling back to a different MinIO edition.

**Backward compatibility:** entirely internal to `storage-service`'s
`internal/blob` package. Zero change to the Node sidecar, `digital-factory-ui`,
`hermes-agent`, `workflow-mcp`, or any git-backed (`ts`-owner) path — none of
them touch the blob SDK or hold a presigned URL.

### Required skills

- go-best-practices

### Subtasks

- [ ] Add `github.com/minio/minio-go/v7` dependency; remove
      `cloud.google.com/go/storage`
- [ ] Rewrite `blob.Store`'s Upload/Download/Delete methods against the MinIO
      SDK, keeping `document.BlobStore`/`migration.BlobUploader`/
      `admin.GCSDeleter`'s method signatures unchanged (rename
      `GCSDeleter`→`BlobDeleter` as a drive-by cleanup)
- [ ] Migration: rename `blob.gcs_path` column → `blob.object_key`; update
      `internal/admin/store.go` and the `"gcs_path"` JSON field in
      `internal/admin/handler.go`
- [ ] Config: replace `GCS_BUCKET`/`GOOGLE_APPLICATION_CREDENTIALS` with
      `MINIO_ENDPOINT`/`MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY`/`MINIO_BUCKET`/
      `MINIO_USE_SSL`/`MINIO_LICENSE_PATH` in `internal/config/config.go` and
      `.env.template`
- [ ] `docker-compose.yml`: add a local MinIO (AIStor) service with the
      license file bind-mounted for dev
- [ ] Enable bucket versioning on the blob bucket at provisioning/startup
- [ ] Existing tests (`fakeBlobStore`, `mockGCS`→`mockBlobDeleter`) continue
      passing unmodified (interface-based, no GCS/MinIO reference) —
      regression check
- [ ] New unit tests for `blob.Store` against the MinIO SDK (can use MinIO's
      own test server or an interface-level fake, matching the existing
      untested-`blob.Store` gap noted in the survey)

---

## T20 — `workflow-mcp` document read/write MCP tools

### Description

Amendment (2026-07-09, technical design §13). Adds two tools to
`workflow-mcp` (`src/tools.ts`), following its existing tool-registration
pattern (types → handler function → `server.tool(...)` registration → tests
→ README/AGENTS.md update, best exemplified by `unblock_task`):

- `read_storage_document({feature_id, kind})` — reads a `go`-owned feature's
  document content via `/bff/storage-service/api/workspaces/:wid/features/:fid/documents`
  (T6).
- `write_storage_document({feature_id, kind, content})` — writes/imports
  markdown content via `storage-service`'s document-create/import endpoint
  (T6); content is sent as a JSON string field — no multipart/binary body
  support needed for this text-only case.

Both reuse `BffClient`'s existing `Cookie`-header injection
(`WORKFLOW_SESSION_COOKIE`) and error formatting — no new credential, no new
auth scheme. A new thin client (or an extended `BffClient`) targets
`storage-service`'s base URL via the `/bff/storage-service/*` prefix (T4,
done), following the `WORKFLOW_BFF_URL` config pattern in `src/config.ts`.

**Scope guard:** both tools operate only on `go`-owned features'
`storage-service`-backed documents. Neither reads nor writes git. This is
what keeps the change backward compatible — a `ts`-owned feature's documents
remain reachable only through the Claude Code executor's existing
clone-and-`Read` model, with zero involvement from these tools.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] `read_storage_document` tool: types, handler, zod schema, registration
- [ ] `write_storage_document` tool: types, handler, zod schema, registration
- [ ] New client (or `BffClient` extension) targeting
      `/bff/storage-service/*`, reusing the existing session-cookie auth
- [ ] Error formatting consistent with `formatBffError()`'s existing pattern
- [ ] Unit tests mirroring `src/tools.test.ts`/`src/bffClient.test.ts`
- [ ] Update `README.md` (tool table + architecture diagram) and `AGENTS.md`
      (usage example) per this repo's convention for new tools

---

## T21 — Rework `init-feature`'s `go` branch to call T20's tools

### Description

Amendment (2026-07-09). T13 (done), read directly from its shipped
`SKILL.md`, implements `init-feature` Step 0's `go` branch as a raw `curl`
(via the Bash tool — skills have no native HTTP client) straight to
`$STORAGE_SERVICE_URL`, **bypassing `workflow-bff` and T4's
`/bff/storage-service/*` prefix entirely**, authenticated with two
purpose-built env vars: `STORAGE_SERVICE_TOKEN` (a static, long-lived shared
bearer secret every developer must provision in `.env`) and
`STORAGE_SERVICE_ACTOR_USER_ID` (a fixed synthetic user id sent as
`X-User-Id`, so every `go`-feature document is attributed to the same fake
actor, not the real human/agent running the skill). This is a parallel
static-secret auth path outside the platform's gateway-issued identity model
— exactly what the product spec's Non-goals rule out — and it breaks
authorship/audit trail.

This task reworks that branch to call T20's `read_storage_document`/
`write_storage_document` MCP tools instead, which reuse `workflow-mcp`'s
existing session-cookie auth (the real actor's identity, routed through the
BFF like every other call). `STORAGE_SERVICE_TOKEN`/
`STORAGE_SERVICE_ACTOR_USER_ID` and the direct-`curl` code path are removed
entirely. The `ts` branch is **not** touched — same hard-stop discipline as
before (if the `go`/`ts` choice isn't explicit, ask again, don't guess); `ts`
features never call `storage-service` at all, before or after this task.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Replace the `go` branch's direct `curl` calls with calls to T20's
      `write_storage_document` tool (one call per narrative document:
      `product-spec.md`, `technical-design.md`, `tasks.md`, `handoffs/`)
- [ ] Remove `STORAGE_SERVICE_TOKEN`/`STORAGE_SERVICE_ACTOR_USER_ID` from the
      skill's required-env-var list and from `.env.template`; remove the
      now-unused direct-`curl`/BFF-bypass code path from T13's SKILL.md
- [ ] `ts` branch behavior verified unchanged (regression check)
- [ ] Tests: `go` path calls T20's tools (mocked), `ts` path creates git
      files as before, unchanged from T13's original tests

---

## T22 — `doc_version` label/pin column + set-label endpoint

### Description

Amendment (2026-07-09, technical design §Amendment / point 3). Adds a
nullable `label` column to `doc_version` (T6/T11's table) and
`POST /api/documents/:id/versions/:version_id/label` (set/clear a label,
e.g. "sent for approval"). Metadata-only — no change to T11's
snapshot/diff/restore mechanics.

### Required skills

- go-best-practices

### Subtasks

- [ ] Migration: add nullable `doc_version.label` column
- [ ] `POST /api/documents/:id/versions/:version_id/label` endpoint (set/clear)
- [ ] Include `label` in T11's list-versions response
- [ ] Unit tests: set, clear, included in list response

---

## T23 — Label/pin a version in the history panel

### Description

Amendment (2026-07-09). Small addition to T12's version-history panel: a
label input/badge per timeline entry (consuming T22's endpoint via T4's BFF
prefix), with labeled versions visually distinguished (e.g. a pin icon) from
unlabeled autosave snapshots.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Label input/action on a timeline entry, calling T22's set-label endpoint
- [ ] Visual distinction for labeled vs. unlabeled versions in the timeline list
- [ ] Component tests
