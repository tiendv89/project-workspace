# Product Specification

## Feature
- Feature ID: `storage-service`
- Title: Docs & File Storage Platform — `storage-service`

## Amendment (2026-07-09)

Recorded after all 18 original tasks (T1–T18) were implemented and their PRs
opened (feature status: `in_handoff`). This amendment does not reopen or redo
that work — it revises three forward-looking decisions and appends new tasks
(T19–T23, see `tasks.md`) on top of the completed baseline.

1. **Blob backend: GCS → self-hosted MinIO.** The original "GCS, zero new
   vendor" decision (see the blob-layer Goal below, superseded by this
   amendment) is reversed in favor of a self-hosted MinIO deployment (AIStor),
   licensed by the human. Two things drove this: MinIO's native object/bucket
   versioning is a useful complement to this feature's own `doc_version`
   snapshot history (see point 3), and self-hosting removes the GCP
   dependency. This is an internal swap inside `storage-service`'s
   `internal/blob` package only — no other repo's integration surface
   changes: no consumer (including the Node Hocuspocus sidecar) ever calls
   the GCS/MinIO SDK directly or receives a presigned URL, every read/write
   already goes through `storage-service`'s own HTTP endpoints. See `tasks.md`
   T19.
2. **Local-agent document access moves to a `workflow-mcp` tool, not a direct
   HTTP call embedded in a skill.** T13 (done) implemented `init-feature`
   Step 0's `go` branch by having the skill call `storage-service`'s
   document-create endpoint directly from inside `agent-workflow`. On
   reflection this is the wrong layer: every other local-agent-to-backend
   integration in this workspace (task creation, unblocking) goes through
   `workflow-mcp`'s MCP tools, not an ad hoc fetch embedded in one skill. This
   amendment adds document read/write MCP tools to `workflow-mcp` (T20) and
   reworks `init-feature`'s `go` branch to call them instead (T21). This is
   also a first, narrow step on Open Question #3's deferred "Claude Code
   document MCP tool" — full parity with `tech-lead`/`start-implementation`'s
   git-based reads for `ts` features is still not in scope (see Non-goals).
3. **Version history gets a bit more product depth.** T11/T12 (done) ship a
   timeline, diff, and restore. This amendment adds the ability to label/pin
   a specific version (e.g. "sent for approval") so it reads distinctly from
   routine autosave snapshots in the timeline UI (T22/T23).
4. **Hard backward-compatibility constraint, unchanged from the original
   spec and reaffirmed here: nothing in this amendment touches the git-backed
   path for `ts`-owned features.** A `ts` feature's `product-spec.md`/
   `technical-design.md`/`tasks.md`/`handoffs/*.md` continue to live in git
   and are read/written exactly as they are today — by `workflow-backend`'s
   document handler, `hermes-agent`'s `document_repo.py`, and the Claude Code
   executor's clone-and-`Read` model. Both the MinIO swap (internal to
   `storage-service`, transparent to every consumer) and the new
   `workflow-mcp` document tools (scoped to `go`-owned features only — see
   T20/T21's owner guard) are strictly additive. A human authoring a feature
   with `ts` sees no change to their workflow.

## Problem

`product-spec.md`, `technical-design.md`, `tasks.md`, and `handoffs/*.md` are today
plain markdown files committed to the management repo (`project-workspace`) via
GitHub. Three production consumers already depend on that git-file model:

- `workflow-backend`'s `internal/handler/document.go` reads/writes them via the
  GitHub Contents API (`internal/github/client.go`) to serve `digital-factory-ui`'s
  `FeatureDocumentPanel` (view + single-writer, SHA-locked edit).
- `hermes-agent`'s `document_repo.py` implements read-before-write + feature-branch
  commit + PR create/update against the GitHub REST API, exposed as the
  `read_document` / `write_product_spec` / `write_technical_design` / `edit_document`
  agent tools (the chat-copilot's write path).
- Claude Code executor skills (`tech-lead`, `start-implementation`) read these files
  by cloning the management repo and calling `Read` — no MCP tool exists for this
  today, per `executor-self-briefing`'s "the executor clones the management repo,
  reads whatever context it needs" model.

This git-file model has four concrete problems that get worse as usage grows:

1. **No real concurrent editing.** Only one writer can hold the file at a time
   (SHA-based optimistic lock, `StaleDocumentError` / `StaleBaseError` on conflict).
   A human and an agent (or two humans) cannot co-edit a spec live — one has to
   wait for the other's commit.
2. **No version history beyond raw git log.** There is no in-product timeline, diff,
   or restore UI for a document's evolution — only what `git log` on the file
   happens to show.
3. **No file/image upload path.** There is nowhere to paste an image into a spec, a
   technical design, or an agent chat prompt, and no path to import a local `.md`
   file as a new live document.
4. **RAG indexing is git-diff-triggered and will silently stop working the moment
   docs leave git.** `rag-service/services/indexer/git_watcher.py` watches for
   commits; `pr_indexer.py` indexes PRs. Neither fires for a document that isn't a
   git commit.

This is a distinct problem from roadmap item 4 (*workspace storage migration*),
which moves task/feature **state** (`status.yaml` and the per-task `tasks/*.yaml`
files — status, depends_on, log) off GitHub into Postgres. This feature is about
**document content** — `product-spec.md`, `technical-design.md`, `tasks.md`
(the narrative task breakdown — description, subtasks, required skills; distinct
from the per-task `tasks/*.yaml` state files), `handoffs/*.md`, and new arbitrary
uploaded files/images — becoming live, editable documents instead of markdown
files committed to git. The two efforts should share infrastructure where
practical (same object store, same DB) but are separable workstreams — this
feature does not touch `status.yaml` or the per-task `tasks/*.yaml` state files.

## Goals

- **Scope boundary (explicit):** this feature's goals cover **document content**
  — `product-spec.md`, `technical-design.md`, `tasks.md` (the narrative
  breakdown), `handoffs/*.md`, and new uploaded files/images. Migrating
  `status.yaml` and the per-task `tasks/*.yaml` state files (task/feature
  **state**) off git into Postgres is roadmap item 4 (*workspace storage
  migration*) — a separate, already-tracked workstream, explicitly out of scope
  for this feature's goals (see Non-goals). The two efforts may share
  infrastructure (same object store, same DB) but ship independently.
- Stand up a single new service, **`storage-service`** (parallel to `rag-service` /
  `user-service` / `notification-service` in `workspace.yaml`), that owns:
  - a **generic blob layer** wrapping **self-hosted MinIO (AIStor)**
    (superseded by [Amendment (2026-07-09)](#amendment-2026-07-09); originally
    GCS, chosen for zero new vendor over Cloudflare R2 / AWS S3 / Supabase
    Storage / self-hosted MinIO — GCS reuses existing GCP IAM/service-account
    plumbing). MinIO is now chosen for its native object/bucket versioning
    (complements this feature's own `doc_version` snapshot history, see the
    version-history goal below) and to remove the GCP dependency; the human
    provides the AIStor license — upload endpoint, presigned URLs, and file
    metadata for any file (pasted images, chat attachments, future PDFs/design
    assets); Postgres holds all metadata (doc id, current version pointer, ACL,
    workspace_id) as the source of truth, MinIO is bytes-only.
  - a **document domain** built on top of the blob layer: document CRUD, the
    folder-tree read API, snapshot/version history, and markdown import — as
    internal modules (`internal/blob`, `internal/document`) in the same Go
    deployable, not a second service.
- Ship **live collaborative editing** for `product-spec.md` / `technical-design.md`
  using **Yjs** as the CRDT, **Tiptap** (ProseMirror + Yjs) as the editor, and a
  **self-hosted Hocuspocus** sync layer running as a small Node sidecar (own
  Dockerfile/compose entry) — MinIO-backed persistence via Hocuspocus's
  `onStoreDocument`/`onLoadDocument` hooks. The stage-approval gate model is
  unchanged: editing a live doc's content is separate from flipping
  `status: approved`.
- **Authenticate `storage-service` consistently with the rest of the platform,
  and solve the WebSocket gap explicitly rather than skip it.** The workspace's
  gateway (`workflow-bff`) owns sessions and injects trusted identity headers
  into every backend call — but it does not support proxying WebSocket
  connections (a prior feature, agent-chat v4, hit this exact limitation and
  deliberately avoided extending the proxy for it). Since Hocuspocus's live-sync
  protocol requires a genuine WebSocket, this feature must:
  - Authenticate all normal `storage-service` REST calls (including admin
    routes) the same way every other backend does — trusting the gateway's
    injected identity, not a separate auth scheme.
  - Provide a secure way for the browser to open a direct WebSocket connection
    to the sync layer without going through the gateway, using a short-lived
    credential obtained via an already-authenticated REST call — not a raw,
    unauthenticated WebSocket endpoint, and not a change to the shared gateway's
    proxy behavior.
  - Admin routes additionally require the same platform-admin check already
    used by the existing admin panel — not a new admin-auth mechanism.
- Ship **document version history** as a linear timeline (not a branch DAG),
  self-built against Yjs's native snapshot API (`Y.snapshot()` /
  `createDocFromSnapshot()`), backed by a `doc_version` table (doc_id,
  snapshot_ref, parent_version, author, created_at). No paid Tiptap Cloud
  Snapshot/Snapshot Compare extensions — zero ongoing external SaaS spend for
  this feature. **Amended 2026-07-09:** a version can additionally be labeled/
  pinned (e.g. "sent for approval") so it stands out from routine autosave
  snapshots in the timeline UI — the label is `doc_version` metadata, not a
  new storage mechanism. MinIO's own object/bucket versioning (see the
  blob-layer goal above) is enabled underneath as defense-in-depth against
  accidental overwrite/corruption of a snapshot blob; it is not a substitute
  for the app-level `doc_version` timeline, which remains the CRDT-aware
  source of truth for what the UI shows.
- **Amended 2026-07-09 — local-agent document access via `workflow-mcp`.**
  Add document read/write MCP tools to `workflow-mcp` (the local, stdio MCP
  server Claude Code agents already use for task orchestration) so a `go`-
  owned feature's `storage-service`-backed documents are reachable the same
  way task-orchestration calls already are — a first-class MCP tool, not a
  one-off HTTP call embedded in a single skill. `init-feature`'s `go` branch
  (T13, done) is reworked to call this tool instead of hitting
  `storage-service` directly. Scoped strictly to `go`-owned features — a
  `ts`-owned feature's documents are untouched, still git, still read via the
  Claude Code executor's existing clone-and-`Read` model.
- Ship **folder/tree navigation** ("worktree") as a plain read-surface over
  `workspace` → `feature` → `document` (with a `kind`/`slug`, e.g. `product-spec`,
  `technical-design`) — no sub-pages (a document is always a leaf), no CRDT
  involvement, no speculative generic recursive folder table.
- Ship **file upload** through `storage-service`, split into two flows:
  - **Opaque blob uploads** (pasted images in a doc; pasted images in the agent
    chat prompt) — bytes in, stable permission-checked object reference out, no
    parsing.
  - **Document uploads** (`.md` files from the user's local machine — v1 scope is
    `.md` only, no `.docx`/PDF-as-editable-content) — bytes in, parsed
    (markdown → ProseMirror/Yjs content) into a new live `document` row, wired
    into history and the folder tree like any other document.
- Replace the git-triggered RAG indexing path for these documents with an
  **app-level webhook**: `storage-service` calls `rag-service`'s indexer directly
  on doc save, debounced to "N seconds after last edit" or "on publish/version
  snapshot" (not on every keystroke).
- Wire `storage-service` into `init-feature`: extend the existing Step 0
  `go` (DB-backed task state) vs `ts` (git-backed task state) question so it also
  determines the docs backend — `go` ⇒ `product-spec.md`, `technical-design.md`,
  `tasks.md`, and `handoffs/*.md` live in `storage-service`, `ts` ⇒ they stay in
  git as today. Same hard-stop discipline as today: if the choice isn't explicit,
  ask again, don't guess. Scope stays narrow to these narrative documents —
  `status.yaml` and the per-task `tasks/*.yaml` state files are out of scope
  (roadmap item 4's territory).
- Ship a **one-time migration tool** to move existing git-backed
  `product-spec.md`, `technical-design.md`, `tasks.md`, and `handoffs/*.md` into
  `storage-service`, reusing the `.md`-import path in bulk: admin-triggered
  (per-feature and bulk), idempotent (skip or confirm-reimport if a
  `storage-service` doc already exists for that feature+slug), seeding
  `doc_version` #1 as "imported from git @ `<commit-sha>`" to preserve history
  continuity, and firing the RAG webhook per migrated doc. Sourced via a direct
  GitHub Contents API read / shallow clone — explicitly not built on
  `workspace-github-adapter`, since that service is slated for removal and this
  migration tool is a throwaway, one-time job. Per-task `tasks/*.yaml` state
  files are not migrated by this tool (roadmap item 4's territory).
- Ship **soft-delete / trash semantics** as a first-class part of the blob and
  document domain, not just an admin operation:
  - A user who can edit a document or uploaded file can **delete** it (document:
    remove from the folder tree; blob: remove from its referencing doc/message) —
    this sets a `deleted_at` marker, it never hard-deletes the underlying MinIO
    object or Postgres row at delete time.
  - A **trash view**, scoped the same way as the folder tree (§ folder/tree
    navigation goal), lists a workspace's soft-deleted documents/files and offers
    **restore** (clears `deleted_at`, reappears in its original folder location).
  - **Retention + purge policy:** soft-deleted items are permanently purged
    (MinIO object deleted, row hard-deleted) after a fixed retention window (default
    30 days — confirm with the human, see Open Questions) via a scheduled job, or
    immediately by an admin's explicit "empty trash" action on `/admin/storage`.
  - Deleting a document does not delete its version history until the retention
    window's purge runs — a restored document keeps its full `doc_version`
    timeline intact.
  - This is distinct from the admin object browser's orphan cleanup (unattached
    blobs with no referencing doc/message) — trash is for content a user
    intentionally deleted; orphan cleanup is for content that was never properly
    attached in the first place. Both funnel into the same purge job.
- Ship an **admin surface** at `/admin/storage` in `digital-factory-ui`, as a
  sibling page under `m1-admin-panel`'s existing role-guarded layout (not a new
  admin app), backed entirely by routes on `storage-service` itself
  (`/api/admin/storage/...`): usage/quota overview (bytes + object count per
  workspace), an object browser (list/search/filter, delete-to-trash not
  hard-delete), an **empty-trash** action (immediate permanent purge of
  soft-deleted items, bypassing the retention window), orphan cleanup (sweep
  unattached objects older than N days), and
  migration status (git-only / migrated / failed, with retry/trigger inline).
- **Guard `hermes-agent`'s document tools against corrupting `go`-backend
  features.** `hermes-agent`'s chat-copilot write path
  (`read_document`/`write_product_spec`/`write_technical_design`/
  `edit_document`) has no owner-awareness today — it always reads/writes git.
  Once a `go`-backend feature's documents live in `storage-service` instead
  (per the `init-feature` goal above), these tools must not blindly keep
  writing git: doing so would either fail outright or silently create a stray
  git copy that diverges from the canonical `storage-service` document —
  exactly the dual-live-copy problem this spec's Non-goals forbid. This feature
  adds the minimum owner-aware guard so these four tools route to
  `storage-service` for `go`-backend features (reusing whatever read/write
  primitives this feature already builds) while leaving their git-commit
  behavior for `ts`-backend features completely unchanged. This is a narrow
  safety fix, not the full migration of `hermes-agent` onto `storage-service`
  (see Non-goals).

## Non-goals

- **Branch/fork version history.** History is a linear timeline (one parent per
  version), not a version DAG. A future branch/merge model would require a
  different CRDT approach entirely — out of scope here.
- **`.docx`, PDF, or other rich-format document import as editable content.** v1
  document upload/import is `.md` only. PDFs/design assets may still be uploaded
  as opaque blob attachments (the generic blob primitive), just not parsed into
  editable documents.
- **Migrating `status.yaml` or the per-task `tasks/*.yaml` state files off git.**
  That is roadmap item 4 (workspace storage migration) and is explicitly out of
  scope for this feature, which only touches document *content* (including the
  narrative `tasks.md` and `handoffs/*.md` files) — not task/feature *state*.
- **Object-store-native pub/sub-based RAG re-index triggering** (GCS Pub/Sub,
  MinIO bucket notifications, or equivalent). v1 uses an app-level webhook from
  `storage-service` to `rag-service`'s indexer; object-store-native
  notifications are a possible future revisit if the two services need to
  decouple further, not a v1 requirement.
- **Image captioning/OCR for RAG indexing of pasted images.** Only in scope if a
  concrete use case emerges; not built speculatively in v1.
- **Comments/threads anchored to document sections, and multi-user presence UI
  polish.** Presence falls out of Yjs's awareness protocol for free once the sync
  layer exists, but building a dedicated presence/comments UI is not v1 scope.
- **A second, independent "docs backend" axis in `init-feature`, decoupled from
  the existing `go`/`ts` choice.** The docs-backend choice rides along with the
  existing `go`/`ts` Step 0 question; a fully independent axis is not being built
  unless a concrete case demands it later.
- **Dual-live git + `storage-service` copies of a migrated document.** Once a
  feature's docs are migrated, the git copy is frozen/read-only; `storage-service`
  becomes canonical. Parallel dual-write is not supported.
- **Hard delete as a user-facing action.** All user-initiated deletes are soft
  (trash + restore window); only the scheduled purge job or an admin's explicit
  "empty trash" action performs a hard delete.
- **Extending the shared gateway (`workflow-bff`) to proxy WebSocket
  connections.** A prior feature already evaluated and deliberately avoided
  this (choosing SSE instead) because the gateway is shared, critical-path
  infrastructure. This feature achieves live sync without requiring that
  change (see Goals) rather than reopening it.
- **A second, independent authentication/authorization mechanism for
  `storage-service`, separate from the platform's existing gateway-issued
  identity and admin-role check.** New credentials introduced by this feature
  (e.g. a short-lived sync credential for the WebSocket connection,
  service-to-service tokens) are scoped narrowly to the specific gap they close
  and must not become a parallel login/authorization system.
- **A full architectural cutover of `hermes-agent`'s `document_repo.py`/tools,
  `workflow-backend`'s document handler, and a Claude Code document MCP tool
  onto `storage-service` as their primary backend, within this spec's task
  breakdown.** These three existing GitHub-Contents-API consumers (see Problem)
  must eventually cut over fully, and each is a real, non-trivial migration
  surface — but sequencing and scoping that full cutover across three repos is
  deferred to a dedicated technical-design/task breakdown once the platform
  core (this spec) exists, not solved here. **This is narrower than "no change
  to `hermes-agent` at all"** — see Goals for the one exception: a defensive
  owner-guard on `hermes-agent`'s document tools is in scope, to prevent them
  from silently corrupting `go`-backend features' documents (see Goals), even
  though the tools' git-commit logic for `ts` features, and their full
  migration to `storage-service`, are not.

## Acceptance Criteria

- A new `storage-service` exists (Go API + Node Hocuspocus sidecar), deployed
  alongside existing services, with MinIO-backed blob storage and Postgres-backed
  metadata/ACL/version tables.
- A `go`-owned feature's `storage-service`-backed documents are readable and
  writable from a local Claude Code agent via a `workflow-mcp` MCP tool — not
  a one-off HTTP call embedded in a single skill — while a `ts`-owned
  feature's documents continue to be read/written exactly as before (git,
  via the Claude Code executor's clone-and-`Read` model).
- A document's version-history timeline supports labeling/pinning a specific
  version so it is visually distinct from routine autosave snapshots.
- A `go`-backend feature's `product-spec.md`, `technical-design.md`, `tasks.md`,
  or a `handoffs/*.md` document can be opened as a live Tiptap document, edited
  concurrently by two sessions (human+human or human+agent) without a
  conflict/lock error, and both sets of edits are present in the resulting
  document (Yjs CRDT merge, not last-write-wins).
- A document's version history can be browsed as a timeline, any two versions can
  be diffed, and any past version can be restored as the live state.
- A feature's documents are browsable via a folder/tree UI scoped to
  `workspace` → `feature` → `document`, with no support for arbitrary nested
  sub-pages under a document.
- A user can paste an image into a `storage-service`-backed document or into the
  agent chat prompt, and upload a local `.md` file to create a new live document —
  all three flows return a stable, workspace-scoped, permission-checked object
  reference.
- Saving/publishing a `storage-service`-backed document triggers `rag-service`'s
  indexer via the app-level webhook (debounced), and the resulting content is
  retrievable via RAG query shortly after.
- Creating a new `go`-backend feature via `init-feature` creates its
  `product-spec.md`, `technical-design.md`, `tasks.md`, and `handoffs/*.md` in
  `storage-service`, seeded from the existing templates, instead of writing git
  files; `ts`-backend features are unaffected and continue to use git as today.
- An admin can trigger migration of an existing git-backed feature's narrative
  documents (`product-spec.md`, `technical-design.md`, `tasks.md`,
  `handoffs/*.md`) into `storage-service` (single feature or bulk), see
  per-feature migration status, and re-run migration idempotently without
  duplicating documents.
- When an agent (via `hermes-agent`'s chat copilot) calls `write_product_spec`,
  `write_technical_design`, or `edit_document` against a `go`-backend feature,
  the write lands in `storage-service` (not git), and no stray git file is
  created for that feature's documents. The same tools called against a
  `ts`-backend feature behave exactly as they do today (git commit + PR).
- A user can delete a document or uploaded file they can edit; it disappears from
  the folder tree/message but is recoverable from a trash view within the
  retention window, with its version history intact on restore. After the
  retention window (or an admin's "empty trash" action), the object and its
  metadata are permanently purged.
- A `storage-service` REST call made by an authenticated user is authorized
  using the same trusted-identity mechanism every other backend in the
  platform already uses — no separate login or credential scheme for this
  feature.
- A browser can establish a live collaborative-editing WebSocket session to the
  sync layer without that connection being routable by an unauthenticated
  third party, and without requiring changes to the shared gateway's existing
  proxy behavior.
- `/admin/storage` in `digital-factory-ui` shows per-workspace usage, an object
  browser with soft-delete, an orphan-cleanup action, and migration status —
  gated by the same `platform_admin`/`admin` role guard as `/admin/members`,
  reached through the same authenticated request path as every other admin
  action in the product (not a separate admin login).

## Open Questions

These four are flagged as needing an explicit decision before technical design
locks the `init-feature`, migration-tool, and trash/purge behavior (recommendations
noted, not yet confirmed):

1. **Does the docs-backend choice ride along with `init-feature`'s existing
   `go`/`ts` question, or become a second independent axis?** Recommended: ride
   along with `go`/`ts` (this spec's Goals assume that answer) — confirm before
   the technical design finalizes the `init-feature` change.
2. **Frozen vs dual-live git files post-migration?** Once a feature's docs move to
   `storage-service`, does the git copy get frozen/read-only, or stay writable in
   parallel for a transition window? Recommended: frozen (this spec's Non-goals
   assume that answer) — confirm before the migration tool is built.
3. **Sequencing across the three existing GitHub-Contents-API consumers**
   (`workflow-backend`'s document handler, `hermes-agent`'s `document_repo.py`/
   tools, and a future Claude Code document MCP tool) — which cuts over first,
   and can `storage-service`-backed features run correctly with only some
   consumers migrated? This needs its own task breakdown and is explicitly
   deferred (see Non-goals) but should be scheduled as a fast-follow technical
   design once this platform core ships.
4. **Trash retention window length.** Recommended default: 30 days before
   automatic permanent purge. Confirm the exact window (and whether it should be
   workspace-configurable per-workspace) before technical design finalizes the
   purge job's schedule.
