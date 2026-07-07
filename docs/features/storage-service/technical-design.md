# Technical Design

## Feature
- Feature ID: `storage-service`
- Title: Docs & File Storage Platform — `storage-service`

## Current State

**Document content lives in the management repo (`project-workspace`) as plain markdown, read/written by three independent GitHub-Contents-API consumers — confirmed via GitNexus, not assumed:**

1. **`workflow-backend`** (`internal/handler/document.go`, `GetDocumentContent`, ~line 94–194;
   `internal/handler/document_source.go`) — a **read-only view path**: `GET
   /api/workspaces/:wid/features/:fid/documents/:type/content` reads
   `docs/features/<id>/<type>.md` off `feature/<id>` via a live GitHub Contents API
   client, falling back to the base branch, then empty. Serves
   `digital-factory-ui`'s `FeatureDocumentPanel`/`FeatureIDEDocsPanel`
   (`src/components/board/feature-document-panel.tsx`,
   `src/components/features/feature-ide-docs-panel.tsx`) — view/edit toggle,
   `MarkdownContent` (react-markdown) render, `StaleDocumentError` on a 409 SHA
   mismatch. This is single-writer, SHA-locked — not collaborative.
2. **`hermes-agent`**'s `plugins/document_repo.py` (`write_document`,
   `read_document`, `ensure_feature_branch`, `ensure_pr`) implements
   read-before-write + feature-branch commit + create/update PR against the
   GitHub REST API with a shared bot `GITHUB_TOKEN` (env var, no config class,
   scoped to the management repo only). Exposed as agent tools
   `read_document` / `write_product_spec` / `write_technical_design` /
   `edit_document` (`plugins/tools/artifacts.py`, `plugins/tools/edit.py`) — the
   chat-copilot's write path. `src/api/routers/documents.py:save_document_endpoint`
   is the human-save HTTP entry point calling into the same `document_repo`.
3. **Claude Code executor skills** (`tech-lead`, `start-implementation`) clone the
   management repo and call `Read` directly — no MCP tool, no HTTP path, per
   `executor-self-briefing`'s explicit model.

**`rag-service`'s indexer is git-diff-triggered** (confirmed via GitNexus):
`services/indexer/git_watcher.py` (`GitWatcher.changed_files`) does `git pull` +
`git diff --name-only`; `services/indexer/main.py` (`run_multi`, `index_repo`)
drives the poll loop; `services/indexer/pr_indexer.py` (`PrIndexer.index_repo_prs`)
separately indexes merged PR descriptions. `services/indexer/chunker.py`
(`chunk_document`) chunks by `source_type` (whole-file for skills/CLAUDE.md,
512-token sliding window for `product_spec`/`technical_design`/readme, per-entry
for `task_log`). None of this fires for a document that is not a git commit.

**Admin surface precedent** (confirmed via GitNexus, `m1-admin-panel` /
`m4-agent-cost` designs): `digital-factory-ui`'s `src/app/(shell)/admin/layout.tsx`
(`AdminLayout`) guards on `isPlatformAdmin`/`hasPlatformRole`
(`src/utils/platform-role.ts`), backed by `user-service`'s `platform_role` /
`platform_role_assignment` tables (`internal/billing/platform_role_store.go`:
`GetRole`/`HasRole`/`GrantRole`) and a `RequirePlatformRole(<key>)` Gin guard
(`internal/handler/platform_role.go`, `internal/handler/org_admin.go`). A
`/admin/storage` page is a sibling under this existing layout/guard, not a new
shell.

**The real auth/gateway architecture — confirmed via `workflow-bff`'s own README
and `m3-agent-chat-v4`'s technical design, corrected from an earlier assumption
in this design:**

- **`workflow-bff` owns sessions and auth**, not `user-service` per-request.
  It runs the OAuth (Google/GitHub) dance, issues an opaque `session_id`
  HttpOnly cookie, and holds session state server-side in **Redis**. It is the
  frontend's single origin: `ANY /bff/<service>/*` reverse-proxies by
  longest-prefix match (`/bff/workflow-backend/...`, `/bff/user-service/...`,
  `/bff/hermes-agent/...`), stripping the prefix and **injecting a trusted
  identity** (`X-User-Id`, `X-Org-Id`, `X-Accessible-Org-Ids`) plus a shared
  `internal_token` service secret. Backends authorize from those headers —
  **they never see the session cookie.** `hermes-agent`'s `require_identity`
  (`src/api/identity.py:23-49`) already trusts exactly this: BFF-injected
  `X-User-Id`/`X-Org-Id` behind a `GATEWAY_SERVICE_TOKEN` bearer check.
- **`workflow-bff`'s proxy explicitly does not support WebSocket.**
  `internal/app/api/handler/proxy/proxy_handler.go`'s `isWebSocketUpgrade()`
  returns **HTTP 501 Not Implemented** — no hijack, no `gorilla/websocket`. SSE
  (`text/event-stream`) is fully supported (flushed per read, write deadline
  cleared) and requires zero BFF change; WebSocket would require new BFF code.
  **`m3-agent-chat-v4` hit this exact constraint and deliberately chose SSE over
  WebSocket specifically to avoid writing it.** This is directly relevant here:
  Hocuspocus's Yjs sync protocol is a genuine bidirectional binary WebSocket —
  it cannot be reframed as SSE. See §11 for the transport decision this forces.

**GitNexus `list_repos`** confirms the current repo universe:
`project-workspace` (management), `agent-workflow`, `workflow-orchestrator`,
`workflow-mcp`, `digital-factory-ui`, `workflow-bff`, `workflow-backend`,
`rag-service`, `git-nexus`, `workspace-github-adapter`, `user-service`,
`hermes-agent`, `notification-service`. **No `storage-service` repo exists yet —
this feature creates it.**

## Constraints

- **Scope boundary is fixed by the approved product spec:** only document
  *content* — `product-spec.md`, `technical-design.md`, `tasks.md` (narrative),
  `handoffs/*.md`, and new uploaded files/images — moves to `storage-service`.
  `status.yaml` and per-task `tasks/*.yaml` (task/feature *state*) are
  out-of-scope (roadmap item 4). No code in this feature may write those files.
- **No external SaaS cost.** Tiptap Cloud's paid Snapshot/Snapshot Compare
  extensions are explicitly rejected; history must be self-built against the raw
  Yjs snapshot API.
- **GCP-native, zero new vendor for the primary store.** GCS is the object store;
  Postgres holds metadata/ACL — mirrors the roadmap-item-4 pattern (DB is
  source-of-truth for state/metadata, object storage is bytes-only).
- **CRDT sync must self-host.** No Go CRDT library is mature enough; Hocuspocus
  (Node) is the only viable self-hosted sync server for Yjs. This is one
  contained new-language service, not a language-standard change — the shop
  already runs Python (`rag-service`) alongside Go.
- **The gate model does not change.** Editing a live doc is separate from
  `status: approved` stage transitions — approval remains a human/permissioned
  action via `approve_feature`/`request_approval`, untouched by this feature.
- **No sub-pages.** A document is always a leaf under `feature`; no arbitrary
  recursive folder nesting in v1.
- **v1 upload/import is `.md` only** — no `.docx`/PDF-as-editable-content.
- **`workspace-github-adapter` must not be a dependency of the migration tool** —
  it is slated for removal; the migration tool reads GitHub directly.
- **Three existing consumers keep working during rollout.** `workflow-backend`'s
  document handler, `hermes-agent`'s tools, and the executor's clone-and-`Read`
  path are NOT cut over in this feature (see product spec Non-goals) — they must
  continue to serve `ts`-backend features unmodified while `storage-service`
  onboards `go`-backend features in parallel.
- **All new management-repo/`storage-service` writes must go through PRs / normal
  git flow** — no direct commits to `main` (workspace-wide rule).

## Options Considered

### Option A — Single new `storage-service` repo (Go API + Node Hocuspocus sidecar), one deployable pair
- Pros: matches the "one repo, `internal/blob` + `internal/document` modules"
  decision from the discussion doc; parallel to `rag-service`/`user-service`/
  `notification-service` in `workspace.yaml`; one fewer repo/deploy/on-call
  surface; Postgres/GCS clients shared between blob and document code with no
  network hop.
- Cons: couples the generic blob primitive to document-domain logic in one
  codebase; the Node sidecar is a second deployable inside "one service."
- **Chosen.**

### Option B — Split `storage-service` (blobs) and `docs-service` (documents) as two repos
- Pros: cleaner service boundary; blob primitive reusable without pulling in
  document/CRDT logic.
- Cons: two repos/deploys/on-call surfaces for a domain where nothing else is a
  serious blob consumer yet; the discussion doc's own conclusion was to
  collapse this back to one service — re-splitting reopens a decision already
  made explicitly. **Rejected** (matches the approved spec's "one repo" goal).

### Option C — Route new documents through `workspace-github-adapter` instead of a new service
- Pros: no new repo at all.
- Cons: the adapter is scoped to syncing GitHub state into Postgres for
  read-only feature/task metadata, has no blob storage, no CRDT support, and is
  slated for removal — building live-editing on top of a deprecating service is
  a direct contradiction. **Rejected.**

## Chosen Design

### 1. New repo: `storage-service`

One repo, two deployables, matching the approved spec:

- **Go API** (`internal/blob`, `internal/document`) — Gin, pgx/Postgres (consistent
  with `workflow-backend`/`user-service`'s stack), GCS client SDK.
  - `internal/blob`: `POST /api/blobs` (upload, returns `{object_id, url}`),
    `GET /api/blobs/:id` (presigned URL or proxy read), soft-delete
    (`DELETE /api/blobs/:id` → `deleted_at`), Postgres `blob` table
    (`id, workspace_id, gcs_path, content_type, size_bytes, uploaded_by,
    created_at, deleted_at`).
  - `internal/document`: CRUD for `document` rows (`id, workspace_id, feature_id,
    kind` [`product_spec|technical_design|tasks|handoff`], `slug, folder_id NULL,
    current_version_id, created_at, deleted_at`), folder-tree read API
    (`GET /api/workspaces/:wid/features/:fid/documents` → flat list scoped by
    `feature_id` today, `folder` table deferred per spec), `doc_version` table
    (`id, document_id, snapshot_ref [GCS blob id], parent_version_id, author,
    created_at, source` [`edit|import|migration`]), markdown import endpoint
    (`POST /api/documents/import` — parses `.md` → ProseMirror JSON → seeds a
    `Y.Doc` → snapshot #1).
  - Auth: trusts BFF-injected identity headers (`X-User-Id`, `X-Org-Id`,
    `X-Accessible-Org-Ids`) behind a shared internal token, exactly like
    `hermes-agent`'s `require_identity` — not a direct session/cookie check (see
    §11). Workspace-scoped ACL check on every read/write using
    `X-Accessible-Org-Ids`.
- **Node sidecar** (`sync/`, own `Dockerfile`) — Hocuspocus server, reached
  **directly by the browser over its own public WebSocket endpoint** (not via
  `workflow-bff` — see §11 for why).
  - `onAuthenticate`: verifies a short-lived signed **sync token** (see §11) —
    no per-connection network call needed.
  - `onLoadDocument`: reads the current `doc_version.snapshot_ref` blob from GCS
    (via the Go API's internal blob-read, called over localhost/private network
    — not the public API), decodes into a `Y.Doc`.
  - `onStoreDocument`: on debounce (see below), calls `Y.snapshot(ydoc)` →
    `Y.encodeSnapshot()`, POSTs the bytes to the Go API's internal blob-write,
    inserts a `doc_version` row, and fires the RAG webhook.
  - `ydoc.gc = false` set at document creation (once).

### 2. Editor + CRDT stack

**Yjs** (CRDT) + **Tiptap** (ProseMirror + Yjs editor, `digital-factory-ui`) +
**self-hosted Hocuspocus** (sync layer, `storage-service`'s Node sidecar), exactly
as decided in the discussion doc. `digital-factory-ui`'s existing
`FeatureIDEDocsPanel`/`FeatureDocumentPanel` is replaced (for `storage-service`-
backed documents only — `ts` features keep the current markdown panel unchanged)
with a Tiptap+Hocuspocus-connected editor component. Markdown export
(`prosemirror-markdown` / Tiptap's markdown extension) is retained as the
`.md`-download escape hatch and as the migration tool's reverse path.

### 3. Version history

Self-built against `Y.snapshot()`/`Y.encodeSnapshot()`/`Y.createDocFromSnapshot()`,
no Tiptap Cloud. `doc_version` table as above. Restore = decode a past snapshot,
`Y.createDocFromSnapshot`, swap in as the live `Y.Doc` state (broadcast to all
connected Hocuspocus clients). Diff = decode both snapshots to ProseMirror JSON,
recursive structural diff (a small custom differ; no new heavy dependency
justified for v1). Linear timeline only — `doc_version.parent_version_id` is
single-parent by construction, no branch/merge support.

### 4. Folder/tree navigation

Plain read API over `document` rows scoped by `workspace_id`/`feature_id`; no
`folder` table in v1 (per spec, added only if arbitrary user folders become a
concrete need). UI: a sidebar tree component in `digital-factory-ui` — reuse
HeroUI's existing list/tree primitives (checked: no new dependency needed for
this shallow, bounded shape).

### 5. File upload

Two flows through `internal/blob`:
- **Opaque blobs** — pasted image in a Tiptap doc, pasted image in
  `digital-factory-ui`'s agent chat prompt input (`src/components/agent-chat/`).
  For the chat-image case, `digital-factory-ui` calls `storage-service`'s upload
  endpoint directly (BFF-proxied, `workflow-bff` adds a thin
  `/bff/storage-service/*` passthrough alongside its existing
  `/bff/workflow-backend`, `/bff/hermes-agent`, `/bff/user-service` clients),
  then passes the resulting object reference to `hermes-agent` as part of the
  chat turn payload — `hermes-agent` fetches the bytes via the object reference
  and attaches as an image content block to the Claude API call. This reuses
  `m3-agent-chat`'s existing message-attachment shape where present; extend
  rather than replace it if such a shape already exists (verify at
  implementation time).
- **Document uploads (`.md` import)** — `internal/document`'s import endpoint,
  as above.

### 6. RAG re-index trigger

App-level webhook: Hocuspocus's `onStoreDocument` (after writing the snapshot)
calls `rag-service`'s indexer with `{workspace_id, feature_id, document_kind,
content}` over HTTP — a new `POST /internal/index` endpoint on `rag-service`,
guarded by a shared internal token (mirrors the `GITHUB_TOKEN`-gated internal
pattern already used for `pr_indexer`). Debounced at the same point the snapshot
is taken (N seconds after last edit, or on publish/version-snapshot) — not on
every keystroke, consistent with `chunker.py`'s existing per-source-type chunking
(`product_spec`/`technical_design` get the 512-token sliding window; the same
applies to `tasks`/`handoff` content once webhook-triggered). `git_watcher.py`/
`pr_indexer.py` remain unchanged and continue to serve `ts`-backend features.

### 7. `init-feature` wiring

Extends the existing Step 0 `go`/`ts` question (no second axis, per spec):
`go` ⇒ `init-feature` calls `storage-service`'s document-create endpoint to seed
`product-spec.md`, `technical-design.md`, `tasks.md`, and `handoffs/` from the
existing templates (`<WORKSPACE_ROOT>/workflow/templates/feature/`) as
`storage-service` documents instead of writing local git files. `ts` ⇒ unchanged
(current git-file behavior). This touches the `agent-workflow`/`init-feature`
skill and `workflow-backend`'s `CreateFeature` path (per
`feature-initialization-compatible`'s existing `owner`-branching pattern —
extend, don't duplicate, the `ts`/`go` fork already there).

### 8. Migration tool

One-time, admin-triggered, reuses the `.md`-import path (§5) in bulk. Reads
`product-spec.md`/`technical-design.md`/`tasks.md`/`handoffs/*.md` bytes directly
via the GitHub Contents API (a scoped, throwaway client in `storage-service` or a
one-off script — explicitly not built on `workspace-github-adapter`). Idempotent
per feature+slug (checks for an existing `document` row before creating).
Seeds `doc_version` #1 with `source: "migration"` and a note recording the
source commit SHA. Fires the RAG webhook (§6) per migrated doc. Once migrated,
the git file is frozen (read-only) — enforced by `workflow-backend`'s document
handler being updated to 403 write attempts on a migrated feature's `ts`-style
paths (small guard addition, not a rewrite of that handler — full cutover of
that handler is out of scope per spec Non-goals).

### 9. Trash / soft-delete

`blob.deleted_at` and `document.deleted_at` columns (§1). User-facing delete
(`DELETE /api/documents/:id`, `DELETE /api/blobs/:id`) sets `deleted_at`, hides
from folder-tree/message reads. A `GET /api/workspaces/:wid/trash` endpoint lists
soft-deleted items for a workspace; `POST /api/.../restore` clears `deleted_at`.
A scheduled purge job (cron in the Go API, or a lightweight worker) hard-deletes
GCS objects + rows where `deleted_at < now() - retention_window` (default 30
days, see product spec Open Question #4 — confirm before this job's schedule is
finalized). Admin "empty trash" action (`/admin/storage`) calls the same purge
logic immediately, scoped to a workspace or item.

### 10. Admin surface

`/admin/storage` in `digital-factory-ui`, sibling to `/admin/members` under the
existing `AdminLayout`/`isPlatformAdmin` guard (§ Current State) — no new
shell/auth. Backend: all routes under `/api/admin/storage/...` live on
`storage-service` itself (owns the tables). Auth mechanics for these routes are
specified in §11 (BFF-injected identity + a service-to-service platform-role
check against `user-service`), not re-derived here. Surfaces: usage/quota per
workspace, object browser with delete-to-trash, empty-trash action, orphan
cleanup (blobs with no referencing `document`/chat-message older than N days),
migration status per feature (git-only/migrated/failed, retry inline).

### 11. BFF, authentication, and the live-sync transport decision

**REST API auth (`storage-service`'s Go API, including admin routes).** Add
`/bff/storage-service/*` as a new upstream prefix in `workflow-bff`'s existing
longest-prefix proxy config (`configs/config.yaml`'s `bff.upstreams` —
config-only change, same shape as the existing `/bff/workflow-backend`,
`/bff/hermes-agent`, `/bff/user-service` entries; confirmed no per-route
registration is needed, matching the `ui-go-owned-task-status-and-block`
precedent for a new sibling path under an existing root-path prefix).
`storage-service` trusts the BFF-injected `X-User-Id`/`X-Org-Id`/
`X-Accessible-Org-Ids` headers behind the shared `internal_token` bearer check
— the identical trust model `hermes-agent`'s `require_identity` already uses,
reused rather than reinvented. Every read/write is additionally scoped by
`X-Accessible-Org-Ids` (workspace membership), mirroring `workflow-backend`'s
`AuthCtx.AccessibleWorkspaceIDs` pattern.

**Admin routes** (`/api/admin/storage/...`) additionally require a
platform-role check. `storage-service` calls `user-service`'s existing internal
role-check surface service-to-service (shared internal token, same shape as
`user-service`'s existing `/internal/sessions/validate` — confirm the exact
endpoint name for platform-role lookup at implementation time; `HasRole`/
`GetRole` in `internal/billing/platform_role_store.go` are the underlying
functions) using the `X-User-Id` from the trusted header. This avoids inventing
a second admin-auth mechanism alongside the one `m1-admin-panel`/`m4-agent-cost`
already established.

**Live-sync transport (Hocuspocus WebSocket) — Options Considered:**

- **Option WS-A — extend `workflow-bff`'s proxy to support WebSocket.**
  Pros: single origin for the browser; the existing session cookie/Redis auth
  is reused as-is, no new token scheme.
  Cons: `workflow-bff` is a shared, critical-path gateway serving every other
  service; WebSocket proxying is new code with new failure modes (long-lived
  connections, backpressure, reconnect-on-drop semantics) that
  `m3-agent-chat-v4` explicitly avoided by choosing SSE instead, specifically
  to not touch this code path. Re-opening that avoided work here, for one
  feature, has a blast radius beyond this feature if it destabilizes the shared
  proxy. **Rejected** — inconsistent with established precedent and
  disproportionate risk for this feature's scope.
- **Option WS-B — Hocuspocus exposes its own public WebSocket endpoint,
  authenticated by a short-lived signed sync token minted via the
  BFF-authenticated REST path (chosen).** The browser's Tiptap collaboration
  provider first calls `POST /bff/storage-service/api/documents/:id/sync-token`
  (normal BFF-authenticated REST call, identity + ACL checked exactly as this
  section describes above) to obtain a short-TTL (~60s) HMAC-signed token
  carrying `{workspace_id, document_id, user_id, exp}`, signed with a secret
  (`STORAGE_SYNC_TOKEN_SECRET`) known only to `storage-service`'s Go API and its
  own Node sidecar — not to `workflow-bff`. The browser then opens a WebSocket
  directly to the Hocuspocus sidecar's own public endpoint, presenting the token
  (query param or `Sec-WebSocket-Protocol`). Hocuspocus's `onAuthenticate` hook
  verifies the signature, expiry, and claims locally — no network call per
  connection. On token expiry mid-session (long editing sessions), the client
  re-fetches a fresh token through the same authenticated REST path before
  reconnecting.
  Pros: zero new code in `workflow-bff`; matches Hocuspocus's own idiomatic
  self-hosted auth pattern; the REST path (fronted by the BFF, already
  authenticated/ACL-checked) remains the single source of truth for "is this
  user allowed to see this document," and the WS layer only verifies a
  short-lived capability rather than re-deriving permissions.
  Cons: a second public network endpoint (the Hocuspocus WS host) that sits
  outside the BFF's single-origin model — needs its own TLS/ingress
  configuration and a WS-origin/CORS allowlist; requires a token-refresh path
  in the client for sessions longer than the token TTL.
  **Chosen.**

**Service-to-service internal tokens** (distinct secrets per pair, following the
workspace's existing pattern of scoped bot/service credentials —
`GITHUB_TOKEN` for `hermes-agent`, `internal_token` for `workflow-bff`, rather
than one shared platform-wide secret):
- `STORAGE_INTERNAL_TOKEN` — shared between `storage-service`'s Go API and its
  own Node Hocuspocus sidecar, for the sidecar's calls back into the Go API's
  internal blob read/write endpoints (`onLoadDocument`/`onStoreDocument`, §1).
- `STORAGE_SYNC_TOKEN_SECRET` — as above, for signing/verifying sync tokens
  (WS-B); distinct from `STORAGE_INTERNAL_TOKEN` since it is a signing key
  embedded in a client-visible token, not a bearer credential.
- A `rag-service`-side shared token for the `POST /internal/index` webhook
  (§6) — mirrors the existing `GITHUB_TOKEN`-gated internal pattern already
  used for `pr_indexer`.
- `hermes-agent` obtains an image's bytes for the vision-model call (§5) by
  calling `storage-service`'s internal blob-read endpoint with a new shared
  service credential (`STORAGE_SERVICE_TOKEN`, held by `hermes-agent` alongside
  its existing `GITHUB_TOKEN`), passing the `object_id` it received in the
  chat-turn payload — the same shape as its existing scoped-bot-credential
  pattern, not a new mechanism.

## Dependency Analysis

- **`storage-service` (new repo) is the foundation** — Go API (blob + document +
  history + folder-tree + import) must exist before anything else in this
  feature can be built.
- **Node Hocuspocus sidecar depends on the Go API's internal blob read/write
  endpoints** (§1) for `onLoadDocument`/`onStoreDocument` — must be built after
  or alongside the Go API's blob module, not before.
- **`digital-factory-ui`'s Tiptap editor** depends on both the Go API (folder
  tree, document CRUD, history reads) and the Hocuspocus sidecar (live sync
  connection) being reachable — cannot be usefully tested standalone.
- **RAG webhook (§6)** depends on `rag-service` exposing the new
  `POST /internal/index` endpoint — a small, independent addition to
  `rag-service` that can be built in parallel with `storage-service`'s core.
- **`init-feature` wiring (§7)** depends on `storage-service`'s document-create
  endpoint existing and stable — sequenced after the Go API's document module.
- **Migration tool (§8)** depends on `storage-service`'s import endpoint (§5) and
  is otherwise independent of live-editing (§2/§3) — could ship before Tiptap
  integration if sequencing pressure requires, since it only needs the write
  path, not the CRDT sync layer.
- **Admin surface (§10)** depends on: `storage-service`'s usage/object/trash/
  migration-status read APIs, and the §11 platform-role check being reachable
  from `storage-service` via a service-to-service call to `user-service`.
- **The BFF proxy config change (§11, new `/bff/storage-service/*` upstream)**
  is a small, independent, additive change to `workflow-bff` that can happen in
  Wave 1 — it is a prerequisite for every REST call in this feature but is not
  itself blocked on anything.
- **The Hocuspocus WebSocket endpoint (§11, WS-B) is deliberately NOT routed
  through `workflow-bff`** — it needs its own ingress/TLS setup, independent of
  the BFF proxy change above. This is a genuinely separate piece of
  infrastructure work from the REST API's BFF wiring and should be scoped as
  its own task.
- **No dependency on `workspace-github-adapter`** anywhere in this feature
  (constraint, §Constraints) — the migration tool reads GitHub directly.
- **No dependency on cutting over `workflow-backend`'s document handler,
  `hermes-agent`'s tools, or the executor's clone-and-`Read` path** — those
  three consumers continue serving `ts`-backend features unmodified throughout
  this feature's rollout (per spec Non-goals); this feature only adds a new,
  parallel path for `go`-backend features.

## Parallelization / Blocking Analysis

```
Wave 1 (parallel, no blockers):
  - storage-service: repo scaffold + Postgres schema (blob, document, doc_version)
    + GCS client wiring + internal/blob module (upload, presigned URL, soft-delete)
  - rag-service: POST /internal/index endpoint (additive, independent of storage-service)
  - digital-factory-ui: folder-tree sidebar component (can be built against a
    mocked document-list API; HeroUI primitives, no new dependency)
  - workflow-bff: add /bff/storage-service/* upstream prefix (config-only, §11)
  - infra: provision the Hocuspocus WebSocket endpoint's own public
    ingress/TLS (§11, WS-B) — independent of the BFF change above; needed
    before Wave 3's Tiptap integration can connect end-to-end

Wave 2 (depends on Wave 1's blob module):
  - storage-service: internal/document module (CRUD, doc_version, markdown import,
    folder-tree read API) — depends on internal/blob for snapshot storage
  - storage-service: Node Hocuspocus sidecar (onLoadDocument/onStoreDocument/
    onAuthenticate against the §11 sync token) — depends on internal/blob's
    internal read/write endpoints
  - storage-service: sync-token mint endpoint (POST .../sync-token, §11) —
    depends on the Go API's identity/ACL middleware from Wave 1

Wave 3 (depends on Wave 2):
  - digital-factory-ui: Tiptap editor component wired to Hocuspocus + document
    CRUD/history APIs — replaces FeatureIDEDocsPanel's content pane for
    storage-service-backed documents only
  - storage-service: RAG webhook wiring in onStoreDocument → rag-service's
    /internal/index (depends on rag-service's Wave-1 endpoint + Hocuspocus
    existing)
  - storage-service: version-history timeline UI API (list/diff/restore) +
    digital-factory-ui history panel

Wave 4 (depends on Wave 2's document module, parallel with Wave 3):
  - agent-workflow: init-feature Step 0 wiring — go ⇒ storage-service document
    create (depends on storage-service's document-create endpoint only, not on
    Tiptap/Hocuspocus)
  - storage-service: migration tool (direct GitHub read + bulk import) — depends
    on the import endpoint (Wave 2), independent of Wave 3's live-editing UI

Wave 5 (depends on storage-service's usage/object/trash/migration-status APIs
         from Waves 1-4, and user-service's existing platform_role check):
  - storage-service: admin API routes (/api/admin/storage/...) — usage, object
    browser, empty-trash, orphan cleanup, migration status
  - digital-factory-ui: /admin/storage page under existing AdminLayout guard
```

**What is NOT touched by any wave above, and must remain stable throughout:**
`workflow-backend`'s `internal/handler/document.go` (GitHub-Contents-API view
path for `ts` features), `hermes-agent`'s `document_repo.py` and its four
document tools, and the Claude Code executor's clone-and-`Read` model. These
three consumers' eventual migration to `storage-service` is explicitly deferred
to a fast-follow technical design (per product spec Non-goals / Open Question
#3) and is out of scope for this feature's task breakdown.

## Repository Impact

| Repo (new/existing) | Changes |
|---|---|
| `storage-service` (**new**) | Go API (`internal/blob`, `internal/document`), Postgres migrations, Node Hocuspocus sidecar (`sync/`), Dockerfiles for both, admin API routes |
| `rag-service` | New `POST /internal/index` endpoint (additive); no changes to `git_watcher.py`/`pr_indexer.py` |
| `digital-factory-ui` | New folder-tree sidebar component; Tiptap editor component (storage-service-backed docs only); version-history panel; `/admin/storage` page under existing `AdminLayout`; `workflow-bff` client for `storage-service` |
| `workflow-bff` | New `/bff/storage-service/*` upstream prefix (config-only, `bff.upstreams`) for the REST API; the Hocuspocus WebSocket endpoint is explicitly NOT routed through the BFF (§11) — it is its own public ingress |
| `agent-workflow` (`init-feature` skill) | Extend Step 0 `go`/`ts` fork to call `storage-service`'s document-create endpoint for `go` features |
| `workflow-backend` | Small guard addition: reject writes to a migrated feature's git document paths (403) — not a rewrite of `document.go` |
| `user-service` | No schema changes — `storage-service` calls its existing internal platform-role check service-to-service (§11); no new endpoint expected but confirm at implementation time |
| `hermes-agent` | New `STORAGE_SERVICE_TOKEN` credential (§11) to fetch blob bytes for chat-image attachments — held alongside its existing `GITHUB_TOKEN`; no change to its document tools (deferred per Non-goals) |

Repos explicitly unaffected: `hermes-agent` (its document tools are unchanged in
this feature — deferred per Non-goals), `git-nexus`, `workspace-github-adapter`,
`notification-service`, `workflow-orchestrator`, `workflow-mcp`.

## Open Items Carried From Product Spec

These remain open per the approved spec and should be confirmed before the task
breakdown finalizes the affected task's scope:

1. Docs-backend axis rides along with `go`/`ts` (assumed in §7 above) — confirm.
2. Frozen vs dual-live git files post-migration (assumed frozen, §8 above,
   implemented via the `workflow-backend` guard) — confirm.
3. Sequencing of the three existing GitHub-Contents-API consumers' eventual
   cutover — deferred to a fast-follow technical design, not this feature.
4. Trash retention window length (assumed 30 days, §9 above) — confirm before
   the purge job's schedule is coded.
