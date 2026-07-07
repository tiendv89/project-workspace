# Product Specification

## Feature
- Feature ID: `storage-service`
- Title: Docs & File Storage Platform — `storage-service`

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
  - a **generic blob layer** wrapping **GCS** (chosen over Cloudflare R2 / AWS S3 /
    Supabase Storage / self-hosted MinIO — GCS reuses existing GCP IAM/service-account
    plumbing with zero new vendor) — upload endpoint, presigned URLs, and file
    metadata for any file (pasted images, chat attachments, future PDFs/design
    assets); Postgres holds all metadata (doc id, current version pointer, ACL,
    workspace_id) as the source of truth, GCS is bytes-only.
  - a **document domain** built on top of the blob layer: document CRUD, the
    folder-tree read API, snapshot/version history, and markdown import — as
    internal modules (`internal/blob`, `internal/document`) in the same Go
    deployable, not a second service.
- Ship **live collaborative editing** for `product-spec.md` / `technical-design.md`
  using **Yjs** as the CRDT, **Tiptap** (ProseMirror + Yjs) as the editor, and a
  **self-hosted Hocuspocus** sync layer running as a small Node sidecar (own
  Dockerfile/compose entry) — GCS-backed persistence via Hocuspocus's
  `onStoreDocument`/`onLoadDocument` hooks, and connection-time auth via its
  `onAuthenticate` hook. The stage-approval gate model is unchanged: editing a
  live doc's content is separate from flipping `status: approved`.
- Ship **document version history** as a linear timeline (not a branch DAG),
  self-built against Yjs's native snapshot API (`Y.snapshot()` /
  `createDocFromSnapshot()`), backed by a `doc_version` table (doc_id,
  snapshot_ref, parent_version, author, created_at). No paid Tiptap Cloud
  Snapshot/Snapshot Compare extensions — zero ongoing external SaaS spend for
  this feature.
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
    this sets a `deleted_at` marker, it never hard-deletes the underlying GCS
    object or Postgres row at delete time.
  - A **trash view**, scoped the same way as the folder tree (§ folder/tree
    navigation goal), lists a workspace's soft-deleted documents/files and offers
    **restore** (clears `deleted_at`, reappears in its original folder location).
  - **Retention + purge policy:** soft-deleted items are permanently purged
    (GCS object deleted, row hard-deleted) after a fixed retention window (default
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
- **GCS Pub/Sub-based RAG re-index triggering.** v1 uses an app-level webhook from
  `storage-service` to `rag-service`'s indexer; Pub/Sub is a possible future
  revisit if the two services need to decouple further, not a v1 requirement.
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
- **Cloudflare R2/CDN fronting for images.** Worth doing later if pasted-image
  egress volume becomes meaningful, but not required to ship v1 on GCS directly.
- **Moving `hermes-agent`'s `document_repo.py`/tools, `workflow-backend`'s document
  handler, and a Claude Code document MCP tool onto `storage-service` all within
  this spec's task breakdown.** These three existing GitHub-Contents-API consumers
  (see Problem) must eventually cut over, and each is a real, non-trivial
  migration surface — but sequencing and scoping that cutover across three repos
  is deferred to a dedicated technical-design/task breakdown once the platform
  core (this spec) exists, not solved here.

## Acceptance Criteria

- A new `storage-service` exists (Go API + Node Hocuspocus sidecar), deployed
  alongside existing services, with GCS-backed blob storage and Postgres-backed
  metadata/ACL/version tables.
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
- A user can delete a document or uploaded file they can edit; it disappears from
  the folder tree/message but is recoverable from a trash view within the
  retention window, with its version history intact on restore. After the
  retention window (or an admin's "empty trash" action), the object and its
  metadata are permanently purged.
- `/admin/storage` in `digital-factory-ui` shows per-workspace usage, an object
  browser with soft-delete, an orphan-cleanup action, and migration status —
  gated by the same `platform_admin`/`admin` role guard as `/admin/members`.

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
