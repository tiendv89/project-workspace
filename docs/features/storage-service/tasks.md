# Tasks — storage-service

Feature status: `in_tdd` | Stage: `tasks` | Machine state lives in `tasks/T<n>.yaml`.

## Bootstrap note (read before working any task in this feature)

`storage-service` is a **brand-new repo** that does not exist yet — it is not
indexed in GitNexus, so it cannot be a valid `repo` value for a task until it
is created and GitNexus completes an indexing cycle against it. This creates a
chicken-and-egg problem for a normal one-shot task breakdown.

**Resolution:** **T1** bootstraps the repo itself (targets `project-workspace`,
the management repo, which already exists) — it creates the `storage-service`
GitHub repo, scaffolds it per the technical design (§1: Go API `internal/blob`
+ `internal/document` skeleton, Node `sync/` Hocuspocus sidecar skeleton, both
Dockerfiles), and registers it in `workspace.yaml`. Once T1 merges and GitNexus
re-indexes (an operational step outside this task's control — confirm the
indexing cycle has picked up `storage-service` before proceeding), the
remaining `storage-service`-targeted tasks below (T5–T11, T14, T17 — all
originally scoped in the approved technical design's Waves 1–5) must be
**added to this feature via a follow-up `write_tasks` call**, since
`write_tasks` validates every task's `repo` against GitNexus's live index at
write time and will reject them until then.

**Tasks submitted now** (repo already exists and is indexed): T1, T2, T3, T4,
T13, T15, T16. **Tasks deferred pending T1 + re-index** (repo not yet
indexable): T5, T6, T7, T8, T9, T10, T11, T12, T14, T17, T18 — their full
descriptions are recorded below so no design detail is lost; they are not yet
registered as machine-tracked task YAMLs.

## Index (submitted now)

| ID | Wave | Title | Repo | Depends on | Actor |
|---|---|---|---|---|---|
| T1 | 0 | Bootstrap `storage-service` repo + register in `workspace.yaml` | project-workspace | — | agent |
| T2 | 1 | `POST /internal/index` webhook endpoint | rag-service | — | agent |
| T3 | 1 | Folder-tree sidebar component (mocked API) | digital-factory-ui | — | agent |
| T4 | 1 | Add `/bff/storage-service/*` upstream prefix | workflow-bff | T1 | agent |
| T13 | 4 | `init-feature` Step 0 wiring (go ⇒ storage-service document create) | agent-workflow | T1 | agent |
| T15 | 4 | `hermes-agent` owner guard on the four document tools | hermes-agent | T1 | agent |
| T16 | 4 | Guard: reject writes to a migrated feature's git document paths | workflow-backend | T1 | agent |

## Index (deferred — pending T1 + GitNexus re-index; will be added via follow-up write_tasks)

| ID | Wave | Title | Repo | Depends on (intended) | Actor |
|---|---|---|---|---|---|
| T5 | 1 | Provision Hocuspocus WebSocket public ingress/TLS | storage-service | — | agent |
| T6 | 2 | `internal/document` module (CRUD, doc_version, markdown import, folder-tree read API) | storage-service | T1(bootstrap) | agent |
| T7 | 2 | Node Hocuspocus sidecar (onLoadDocument/onStoreDocument/onAuthenticate) | storage-service | T1(bootstrap) | agent |
| T8 | 2 | Sync-token mint endpoint | storage-service | T1(bootstrap) | agent |
| T9 | 3 | Tiptap editor component wired to Hocuspocus + document/history APIs | digital-factory-ui | T3, T4, T5, T6, T7, T8 | agent |
| T10 | 3 | RAG webhook wiring in `onStoreDocument` | storage-service | T2, T7 | agent |
| T11 | 3 | Version-history timeline API (list/diff/restore) | storage-service | T6 | agent |
| T12 | 3 | Version-history panel UI | digital-factory-ui | T3, T11 | agent |
| T14 | 4 | Migration tool (bulk GitHub import) | storage-service | T6 | agent |
| T17 | 5 | Admin API routes (usage, object browser, empty-trash, orphan cleanup, migration status) | storage-service | T6, T14 | agent |
| T18 | 5 | `/admin/storage` page | digital-factory-ui | T3, T17 | agent |

## Dependency diagram

```
Wave 0 (bootstrap):
  T1  project-workspace  Bootstrap storage-service repo + register in workspace.yaml

Wave 1 (parallel, T1 unblocks T4; T2/T3 have no blockers):
  T2  rag-service        POST /internal/index webhook endpoint
  T3  digital-factory-ui Folder-tree sidebar (mocked API)
  T4  workflow-bff       /bff/storage-service/* upstream prefix        [dep: T1]
  T5  storage-service*   Hocuspocus WS public ingress/TLS              [dep: T1, deferred]

Wave 2 (deferred, dep: T1 + re-index):
  T6  storage-service*   internal/document module
  T7  storage-service*   Node Hocuspocus sidecar
  T8  storage-service*   Sync-token mint endpoint

Wave 3 (deferred):
  T9  digital-factory-ui Tiptap editor + Hocuspocus + document/history APIs   [dep: T3,T4,T5,T6,T7,T8]
  T10 storage-service*   RAG webhook wiring in onStoreDocument                 [dep: T2,T7]
  T11 storage-service*   Version-history timeline API                        [dep: T6]
  T12 digital-factory-ui Version-history panel UI                            [dep: T3,T11]

Wave 4 (T13/T15/T16 submitted now, dep only on T1's repo registration — not on
         the deferred storage-service internal build; T14 deferred):
  T13 agent-workflow     init-feature Step 0 wiring                          [dep: T1]
  T14 storage-service*   Migration tool (bulk GitHub import)                 [dep: T6, deferred]
  T15 hermes-agent       Owner guard on the four document tools              [dep: T1]
  T16 workflow-backend   Guard: reject writes to migrated feature's git paths [dep: T1]

Wave 5 (deferred):
  T17 storage-service*   Admin API routes                                    [dep: T6,T14]
  T18 digital-factory-ui /admin/storage page                                 [dep: T3,T17]

* = repo not yet indexed in GitNexus; task will be registered via follow-up
    write_tasks once T1 merges and indexing completes.
```

**Important dependency caveat for T13/T15/T16 (submitted now):** these three
depend on T1 only for the *repo to exist* — their actual implementation also
functionally depends on `storage-service` exposing real document
read/write/create endpoints (T6, deferred). Do **not** start implementation
work on T13/T15/T16 until T6 has shipped, even though the task-dependency graph
only encodes T1 as the blocker (T6 cannot be encoded as a dependency yet since
it is not yet a registered task). Treat this note as a hard implementation
gate until the deferred tasks are added and the dependency can be made
explicit.

---

## T1 — Bootstrap `storage-service` repo + register in `workspace.yaml`

### Description

Creates the new `storage-service` GitHub repo and scaffolds it per the
approved technical design (§1): a Go API skeleton (`internal/blob`,
`internal/document` package stubs, Gin, pgx, GCS client dependency, Dockerfile)
and a Node `sync/` Hocuspocus sidecar skeleton (package.json, Dockerfile). Adds
`storage-service` as a new `repos[]` entry in `workspace.yaml` (management
repo) so GitNexus indexes it on its next cycle and downstream tasks (T5–T18)
can be registered against a real, resolvable repo. This task does **not**
implement business logic — it is scaffolding + registration only; T6/T7 build
the real modules once this lands.

### Required skills

- go-best-practices

### Subtasks

- [ ] Create the `storage-service` GitHub repo
- [ ] Scaffold Go API: Gin app skeleton, `internal/blob`/`internal/document`
      empty package stubs, pgx config, GCS client dependency, health endpoint,
      Dockerfile
- [ ] Scaffold Node `sync/` Hocuspocus sidecar: package.json, minimal
      Hocuspocus server skeleton, Dockerfile
- [ ] Add `storage-service` to `workspace.yaml`'s `repos[]` (management repo
      PR, following the no-direct-push-to-main rule)
- [ ] Confirm (or note as a follow-up operational step) that GitNexus has
      indexed the new repo before any deferred task below is submitted

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
needed — this mirrors the precedent already established for a new sibling
path under an existing root-path prefix. Identity header injection
(`X-User-Id`/`X-Org-Id`/`X-Accessible-Org-Ids`) applies automatically to the
new prefix, same as every other upstream. Depends on T1 only insofar as the
upstream target host/port needs to be a real (even if not-yet-functional)
service address — coordinate with T1's scaffold for the deployed URL.

### Required skills

- go-best-practices

### Subtasks

- [ ] Add `/bff/storage-service/*` to `bff.upstreams` config
- [ ] Confirm identity-header injection applies to the new prefix (test only,
      no code change expected)
- [ ] Integration test: a request through `/bff/storage-service/*` reaches a
      stub upstream with identity headers present

---

## T13 — `init-feature` Step 0 wiring (go ⇒ storage-service document create)

### Description

Extends the existing Step 0 `go`/`ts` question in the `init-feature` skill
(`agent-workflow` repo) — no second axis. For `go`: calls `storage-service`'s
document-create endpoint (T6, deferred) to seed `product-spec.md`,
`technical-design.md`, `tasks.md`, and `handoffs/` from the existing templates
(`<WORKSPACE_ROOT>/workflow/templates/feature/`) as `storage-service`
documents instead of writing local git files. For `ts`: unchanged (current
git-file behavior). Same hard-stop discipline as today — if the choice isn't
explicit, ask again, don't guess.

**Implementation gate:** this task's code can be written and unit-tested
against a mocked storage-service document-create API now, but must not be
merged/enabled in production until T6 (deferred) actually ships a real
endpoint to call.

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

## T15 — `hermes-agent` owner guard on the four document tools

### Description

Extends the existing `_owner_guard_ts_only` pattern
(`plugins/tools/artifacts.py:264-283`) to `read_document`,
`write_product_spec`, `write_technical_design`, and `edit_document`. For a
`go`-owned feature, each tool proxies to `storage-service`'s document
read/write endpoints (T6, deferred) using a new `STORAGE_SERVICE_TOKEN`
credential instead of committing to git. For `ts`-owned (or absent-owner,
which defaults to `ts`) features, behavior is completely unchanged — no
modification to `document_repo.py`'s git-commit machinery. This is a narrow
defensive guard, not a migration of the tools' primary backend.

**Implementation gate:** can be written and unit-tested against a mocked
storage-service document read/write API now, but must not be merged/enabled in
production until T6 (deferred) ships the real endpoints.

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
after the (deferred) migration tool marks a feature's documents as migrated,
writes to that feature's git document paths are rejected with 403 (the git
copy is frozen/read-only per the approved spec's Non-goals). This is not a
rewrite of `document.go` — the existing read/view path is unchanged; only a
write-path guard is added, keyed off the migration-status tracking that T14
(deferred) will expose.

**Implementation gate:** the guard's check logic can be written now against a
mocked migration-status source, but must not be enabled in production until
T14 (deferred) ships a real migration-status endpoint.

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

## Deferred tasks (full descriptions — to be registered once storage-service is indexed)

### T5 — Provision Hocuspocus WebSocket public ingress/TLS

Provisions the Hocuspocus sidecar's own public WebSocket ingress — deliberately
**not** routed through `workflow-bff` (which rejects WebSocket upgrades with
HTTP 501). Sets up TLS termination and a WS-origin/CORS allowlist for the
sidecar's public endpoint. Independent of T4's BFF change; both are
prerequisites for T9's end-to-end Tiptap↔Hocuspocus connection.

Required skills: go-best-practices

Subtasks:
- [ ] Provision public ingress + TLS termination for the Hocuspocus sidecar's WebSocket endpoint
- [ ] Configure WS-origin/CORS allowlist (frontend origin only)
- [ ] Document the ingress endpoint URL/config for T7/T9 to consume
- [ ] Smoke test: WS handshake succeeds against a stub echo server on the provisioned ingress

### T6 — `internal/document` module (CRUD, doc_version, markdown import, folder-tree read API)

Builds `storage-service`'s document domain on top of T1's blob layer: `document`
CRUD (`id, workspace_id, feature_id, kind` [`product_spec|technical_design|tasks|handoff`],
`slug, folder_id NULL, current_version_id, created_at, deleted_at`), `doc_version`
table + writes, folder-tree read API (`GET /api/workspaces/:wid/features/:fid/documents`),
markdown import endpoint (`POST /api/documents/import`), soft-delete/trash/restore.
This is the second foundation task — T9, T11, T13, T14, T15, T17 all depend on it.

Required skills: go-best-practices

Subtasks:
- [ ] `document` table CRUD (create, read, list-by-feature, soft-delete, restore)
- [ ] `doc_version` table + write path (snapshot_ref, parent_version_id, author, source)
- [ ] Folder-tree read API
- [ ] Markdown import endpoint (.md → ProseMirror JSON → seed Y.Doc → snapshot #1)
- [ ] Trash list + restore endpoints
- [ ] Unit + integration tests

### T7 — Node Hocuspocus sidecar (onLoadDocument/onStoreDocument/onAuthenticate)

Stands up the `sync/` Node deployable running Hocuspocus: `onAuthenticate` verifies
the sync token locally; `onLoadDocument` fetches the current snapshot via internal
blob-read and decodes to a `Y.Doc`; `onStoreDocument` snapshots, encodes, and writes
back via internal endpoints plus a `doc_version` row. Sets `ydoc.gc = false`.

Required skills: typescript-best-practices

Subtasks:
- [ ] Node service scaffold refinement (builds on T1's skeleton)
- [ ] onAuthenticate — verify sync token signature/expiry/claims
- [ ] onLoadDocument — fetch snapshot blob, decode to Y.Doc
- [ ] onStoreDocument — snapshot, encode, write blob + doc_version row
- [ ] ydoc.gc = false at document creation
- [ ] Debounce logic
- [ ] Unit tests (mocked Go API internal endpoints)

### T8 — Sync-token mint endpoint

Adds `POST /bff/storage-service/api/documents/:id/sync-token` — a normal
BFF-authenticated REST call that mints a short-TTL HMAC-signed token for opening
the Hocuspocus WebSocket.

Required skills: go-best-practices

Subtasks:
- [ ] Endpoint implementation, identity/ACL check reuses T1's auth middleware
- [ ] HMAC-sign the token payload
- [ ] Unit tests: valid issuance, ACL rejection, expiry correctness

### T9 — Tiptap editor component wired to Hocuspocus + document/history APIs

Replaces `FeatureIDEDocsPanel`'s content pane with a Tiptap editor for
storage-service-backed documents only. Wires the collaboration provider to
Hocuspocus (via T5's ingress + T8's sync token) and document CRUD/history reads
to the Go API (via T4's BFF prefix). Adds markdown export.

Required skills: typescript-best-practices

Subtasks:
- [ ] Tiptap editor component replacing the content pane for storage-service docs
- [ ] Hocuspocus collaboration provider wiring, sync-token fetch + refresh
- [ ] Document CRUD/history API integration
- [ ] Markdown export action
- [ ] Concurrent-edit test (two sessions, verify CRDT merge)
- [ ] Component/integration tests

### T10 — RAG webhook wiring in onStoreDocument

Extends T7's onStoreDocument hook to call T2's `POST /internal/index` after
each snapshot write, debounced.

Required skills: typescript-best-practices

Subtasks:
- [ ] Call rag-service's internal-index endpoint from onStoreDocument
- [ ] Pass the shared internal token
- [ ] Error handling: webhook failure must not block the snapshot write
- [ ] Integration test (mocked rag-service endpoint)

### T11 — Version-history timeline API (list/diff/restore)

Adds list/diff/restore endpoints on top of T6's doc_version table.

Required skills: go-best-practices

Subtasks:
- [ ] List-versions endpoint
- [ ] Diff endpoint (structural diff of two snapshots)
- [ ] Restore endpoint (swap in live state, notify Hocuspocus to broadcast)
- [ ] Unit tests: list, diff, restore round-trip

### T12 — Version-history panel UI

Adds a history panel in digital-factory-ui consuming T11's endpoints.

Required skills: typescript-best-practices

Subtasks:
- [ ] Timeline list component
- [ ] Diff view
- [ ] Restore action with confirmation
- [ ] Component tests

### T14 — Migration tool (bulk GitHub import)

One-time, admin-triggered tool reusing T6's import path in bulk, reading git
directly (not via workspace-github-adapter), idempotent per feature+slug,
seeding doc_version #1 with source: "migration", firing the RAG webhook per
migrated doc.

Required skills: go-best-practices

Subtasks:
- [ ] Direct GitHub Contents API client (scoped, no workspace-github-adapter dependency)
- [ ] Per-feature migration action with idempotency check
- [ ] Bulk migration action
- [ ] Fire RAG webhook per migrated doc
- [ ] Migration-status tracking exposed for T17
- [ ] Unit tests: idempotent re-run, partial-failure handling

### T17 — Admin API routes (usage, object browser, empty-trash, orphan cleanup, migration status)

Adds `/api/admin/storage/...` routes guarded by a service-to-service
platform-role check against user-service. Implements usage/quota, object
browser, empty-trash, orphan cleanup, migration status, and the scheduled
purge job.

Required skills: go-best-practices

Subtasks:
- [ ] Service-to-service platform-role check against user-service
- [ ] Usage/quota endpoint
- [ ] Object browser endpoint
- [ ] Empty-trash endpoint
- [ ] Orphan-cleanup endpoint
- [ ] Migration-status endpoint
- [ ] Scheduled purge job (retention-window-based)
- [ ] Unit tests

### T18 — `/admin/storage` page

Adds `/admin/storage` to digital-factory-ui, sibling to `/admin/members`,
consuming T17's admin API routes.

Required skills: typescript-best-practices

Subtasks:
- [ ] Page under existing AdminLayout guard
- [ ] Usage/quota overview view
- [ ] Object browser view
- [ ] Empty-trash action
- [ ] Orphan-cleanup action
- [ ] Migration-status view
- [ ] Component tests
