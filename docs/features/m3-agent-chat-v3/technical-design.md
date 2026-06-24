# Technical Design

## Feature
- Feature ID: `m3-agent-chat-v3`
- Title: Agent Chat v3 — Conversational Document Authoring, PR-tracked Commits, and In-UI Approval

> **Current state re-verified against live code on 2026-06-13** (branch `main` of each repo,
> all fetched and up to date). The v1/v2 designs were stale — a BFF front door, an auth
> refactor, a hermes directory rename, and a new SSE envelope landed in the last few days.
> Findings below are grounded in the actual files (paths + symbols cited). RAG MCP was not in
> this session, so the rag-context pre-flight degraded gracefully (no snippets injected).

---

## 1. Current State

### New front door — `workflow-bff` (Go/Gin, created 2026-06-13)
The browser no longer talks to workflow-backend or hermes directly. All FE traffic goes
through **`workflow-bff`** (repo at `~/code/kitelabs/workflow-bff`; now **registered in
`workspace.yaml`**, though v3 needs no BFF change — see below):
- **Generic prefix proxy** (`internal/app/api/handler/proxy/routing.go:66-88`): longest-prefix
  match on `bff_root_path`, strips `/bff/<service>` and forwards the remainder. Services are
  configured by prefix + upstream host (`configs/config.yaml`): `/bff/hermes-agent` →
  hermes, `/bff/workflow-backend` → workflow-backend, `/bff/user-service` → user-service.
- **Any path under a registered prefix is forwarded automatically** — new upstream routes need
  **zero BFF changes**. This is the single most important fact for v3 scoping.
- **Identity injection** (`proxy_handler.go:139-146`): validates the `session_id` cookie
  (Redis session), then injects `Authorization: Bearer <internal_token>`, `X-User-Id`,
  `X-Org-Id`, `X-Accessible-Org-Ids`. The browser's own Cookie/Authorization are **not**
  forwarded. OAuth lives at `/auth/:provider/start|callback`; `X-User-Id` is the OAuth user id.
- **SSE pass-through** (`proxy_handler.go:153-207`): when upstream returns
  `text/event-stream`, the BFF flushes per read with the write deadline cleared — chat
  streaming works through it unchanged.

### hermes-agent (`base_branch: main`) — restructured into a submodule layout
The fork is now vendored as a git submodule; the custom code moved: `workflow_gateway/` → **`src/`**,
`workflow_plugin/` → **`plugins/`**.
- **Gateway routes are under `/api/v1`** (`src/api/router.py`, mounted in `src/app.py:80`):
  `POST /session`, `GET /sessions`, `GET /sessions/{id}/messages`, `POST /chat` (SSE). (The old
  `/api/v5`, `create_session`, `stream_chat` names are gone.)
- **Auth** (`src/api/identity.py:30-40`): every route is `Depends(require_identity)` — a
  `GATEWAY_SERVICE_TOKEN` bearer check (skipped when unset for local dev) plus trusting the
  BFF-injected `X-User-Id` / `X-Org-Id`. **So new gateway routes automatically receive the
  authenticated user id.**
- **Tools** (`plugins/__init__.py:14-76`): `_TOOLS` is a **tuple** of dicts
  `{name, schema, handler, check_fn, is_async?}`, registered via `ctx.register_tool()`. The 7
  live tools are unchanged from v2 (`workflow_get_workspace_context`,
  `workflow_get_feature_state`, `workflow_write_product_spec`, `workflow_write_technical_design`,
  `workflow_get_tasks`, `workflow_query_gitnexus` [async], `workflow_query_rag` [async]).
- **Document writing** (`plugins/tools/artifacts.py`): `handle_write_product_spec` /
  `handle_write_technical_design` → `_put_file()` (`artifacts.py:95-107`) uses the **GitHub
  Contents API PUT**. It **already fetches the current file SHA** via `_get_file_sha()` right
  before writing and includes it — but it sets **no `branch`**, so it commits to the **default
  branch (`main`) directly, with no PR.** `GITHUB_TOKEN` is read at `artifacts.py:118`.
  → **This is a live violation of the management-repo "no direct push to main" rule, and the
  exact write path v3 replaces.**
- **DB** (`plugins/db.py:30-34`): workspace metadata via **psycopg 3 sync**
  (`WORKFLOW_DATABASE_URL`). The gateway's own session store is separate: SQLAlchemy **async**
  asyncpg (`DATABASE_URL`, `src/app.py:46-55`).
- **Hooks** (`plugins/hooks.py:15-95`): `inject_context` injects workspace/feature state + a
  live task summary into the system prompt.
- **SSE envelope** (`src/streaming/sse.py`) — **now OpenAI-compatible**, not the old voyager
  shape: `chat.completion.chunk` deltas + `data: [DONE]`, plus Hermes extensions
  **`hermes.tool.progress`** (`{tool, toolCallId, status: "running"|"completed"}`, with the
  tool output on completion) and **`hermes.artifact.saved`** (`{artifact: "product_spec" |
  "technical_design"}`, emitted only when a write tool returns `ok`).

### workflow-backend (Go/Gin/pgx) — chat proxy REMOVED, BFF auth, document *metadata* only
- HEAD commit `0bdee01` **deleted `internal/handler/chat_proxy.go` entirely** — there are **no
  chat routes here anymore** (the BFF replaced the proxy).
- **Auth refactor**: `/api/*` routes use `authmw.RequireBFFIdentity` (`cmd/api/api.go:87`) —
  validates the service token and reads `X-User-Id` / `X-Org-Id` / `X-Accessible-Org-Ids`;
  handlers get the user via `authmw.FromContext()` → `ac.UserID`. `/internal/*` uses
  `RequireServiceToken`.
- **Feature read** `GET /api/workspaces/:wid/features/:fid` → `domain.FeatureDetail`
  (`internal/domain/dto.go`). **It has no `owner` field** — feature ts/go ownership is **not
  modeled** in workflow-backend today. Tasks read `GET …/features/:fid/tasks` exists.
- **Documents: metadata only, NO content.** `domain.DocumentLink` (`dto.go:103-108`) and the
  `workspace_feature_documents` table (`migrations/00004…`) carry only `document_type`,
  `source_path`, and a GitHub **web** `url` — populated by the workspace-github-adapter sync
  (`internal/github/parser.go:183` maps `product_spec` → `docs/features/<id>/product-spec.md`,
  etc.). There is **no endpoint that returns document content** today, and **no content column**.
- Reads come from Postgres; workflow-backend is **read-only** for feature/task state.

### How document content is read today (the path v3 replaces)
The FE has no content API: `useDocumentContent` (`src/hooks/board/use-document-content.ts:18`)
POSTs the GitHub **web** URL to a Next.js `/api/content/fetch` route and renders the returned
markdown; `FeatureDocument.content?` is an optional field the backend never populates. So document
viewing currently round-trips through GitHub web URLs, not a backend API.

### digital-factory-ui (Next.js 16 / React 19 / Tailwind v4 / HeroUI v3) — BFF integration
- Single base URL `NEXT_PUBLIC_BFF_URL` (`src/constants/axios.ts:6`); clients target
  `${BFF}/bff/workflow-backend`, `${BFF}/bff/hermes-agent`, `${BFF}/bff/user-service`, all with
  `withCredentials: true` (cookie). The browser never sends a user id — the BFF injects it.
- **Layout** (`src/components/features/feature-workbench.tsx:293-610`) — an IDE-style workbench:
  a left **explorer `<aside>`** (feature header + status, artifacts list [product_spec /
  technical_design with approval checkmarks], tasks, chat sessions), a **center** `AgentChatPanel`
  (shown when a session is active), a **right** `FeatureIDEDocsPanel` (always visible — the
  current document), and a collapsible **bottom activity dock**. (There is no separate
  `FeatureStatusPanel`/`FeatureTabView`; those v2 names are gone.)
- **Documents panel** `FeatureIDEDocsPanel` → `FeatureDocumentPanel`
  (`src/components/board/feature-document-panel.tsx`) → renders via `MarkdownContent`
  (`src/utils/markdown.tsx`, react-markdown + remark-gfm + rehypeRaw). Content from a
  `useDocumentContent` hook. **Read-only — no editor.**
- **Chat** `src/components/agent-chat/agent-chat-panel.tsx`: SSE via
  `@microsoft/fetch-event-source` POSTing to `${BFF}/bff/hermes-agent/api/v1/chat` with
  `credentials:"include"`. Tool calls render as **plain chips** (`message-thread.tsx:71-80`,
  `ToolCallRow`: name + running/done). `onArtifactSaved(artifact)` → React Query
  `invalidateQueries(feature(...))` → the documents panel refetches. **No interactive tool-call UI.**
- **Services**: `src/services/hermes-agent/chat.ts` (`createChatSession`, `streamChatTurn`,
  `listChatSessions`, `getSessionMessages`); `src/services/workflow-backend/client.ts`
  (`getFeature`, `searchFeaturesPage`, …).

### Where lifecycle state lives — v3 is `ts`-only
- **Narrative documents** (`product-spec.md`, `technical-design.md`, handoffs) live in the
  **management repo** (`management-repo` = `tiendv89/project-workspace`) under
  `docs/features/<feature_id>/`. hermes already writes there.
- **Stage review state** for a **`ts`** feature is `status.yaml` in that repo (the
  `approve-feature` / `reject-feature` / `set-feature-stage` skills mutate it).
- **`go` features are out of scope for v3** (per product owner: "work for ts only, go later").
  A `go` feature keeps its state in Postgres with no `status.yaml`; its approval write path
  (`workflow-db-mcp`) is a deferred placeholder. v3 does not implement or stub the `go` path —
  the approval/transition endpoint operates on `status.yaml` and simply does not serve `go`
  features. Adding `go` support is a clean follow-on once `workflow-db-mcp` exists.

---

## 2. Problem Framing

**Responsibility split (per product owner): workflow-backend *reads/views* documents; hermes-agent
does *chat + document writes* only.**

### What needs to change
1. **workflow-backend (read/view side)** — add a **document-content view API** that returns the live
   markdown of `product-spec.md` / `technical-design.md` (plus its blob `sha`) from the
   feature branch, and a **document-PR-status** read. This is the FE's read path for both rendering
   and the editor's load-for-edit; it replaces the GitHub-web-URL `/api/content/fetch` hack.
2. **hermes-agent (chat + write side)** — (a) replace the direct-to-`main` Contents PUT with a
   **document-commit pipeline**: commit to `feature/<feature_id>` with read-before-write, and
   **create-or-update one PR per feature**; the agent tool uses it in-process and a gateway
   **`PUT …/document`** endpoint serves the human Save. (b) add a **read-only
   `workflow_request_approval` tool** and a **stage-transition endpoint** that commits the
   `status.yaml` review change (`ts`), actor = `X-User-Id`. hermes exposes **no document *read*
   endpoint** — reads are workflow-backend's job.
3. **digital-factory-ui** — add **edit + preview** to the documents panel (content+sha from
   workflow-backend, Save to hermes), a **PR-status indicator** (from workflow-backend), and
   **interactive tool-call cards** (approval + document-edit) in the chat.

### What does NOT need to change (verified)
- **workflow-bff** — generic prefix proxy; new hermes/workflow-backend routes are reachable
  automatically with identity injection. **No BFF change** (it is now registered in
  `workspace.yaml`, but carries no v3 code).
- **workspace-github-adapter** — workflow-backend reads GitHub directly for the view API
  (§3.4); the adapter's sync path is untouched.
- The SSE transport, the `hermes.artifact.saved` → documents-refetch flow, the auth model, and the
  v2 workbench shell — all reused as-is.

### Fixed assumptions
- New hermes routes inherit `Depends(require_identity)` and thus receive `X-User-Id`
  (the approval actor) and the service-token guard for free.
- `GITHUB_TOKEN` in hermes has push + PR scope on the management repo (it already commits documents
  there). Commits target `feature/<feature_id>`; `main` is reached only by merging the PR.
- workflow-backend's view API reads the management repo over the **GitHub REST API** with a
  read-scoped `GITHUB_TOKEN` (new env in workflow-backend); it reads the `feature/<feature_id>`
  branch (falling back to the base branch / empty when the branch does not yet exist).
- **v3 targets `ts` features only.** The stage-transition operates on `status.yaml`; `go`
  features are out of scope (handled later — see §1, §5).

---

## 3. Options Considered

### 3.1 Where the document commit + PR pipeline lives (one write path — G3/G4)
**Option A — a module in hermes `plugins/` (chosen).** One module (`plugins/document_repo.py`) does
read-before-write + feature-branch commit + create/update PR + PR status. The **agent tool**
calls it in-process; the **human Save** calls thin gateway endpoints that wrap it, reached
**FE → BFF → hermes** (generic proxy). One write path for agent + human.
- Pros: reuses the GitHub-write code + `GITHUB_TOKEN` hermes already has; the BFF already
  fronts hermes for chat, so the human path adds **no new infra and no BFF/workflow-backend
  change**; satisfies G3; fixes the direct-to-`main` violation in one place.
- Cons: a human document-save is served by the agent service. Acceptable — that service already owns
  narrative-document writes; the endpoint is non-chat but same domain.
- **Chosen.**

**Option B — leaf `workspace-github-adapter` service owns commit+PR.** Pros: domain fit. Cons:
new service + new caller graph, duplicates GitHub-write code hermes has, more than v3 needs.
**Rejected** for v3.

**Option C — put it in workflow-backend (Go).** Cons: workflow-backend is read-only today and
has no git-write code; the agent path would still need its own. Two implementations.
**Rejected.**

### 3.2 Concurrency / read-before-write primitive (G5, OQ1)
**Option A — GitHub Contents-API blob-SHA optimistic lock (chosen).** `read_document` returns
`{content, sha}` on the feature branch; `write_document` submits that `sha`; GitHub **rejects a stale
`sha` with 409**, which is the conflict detector. (artifacts.py already fetches the SHA — v3
formalizes it into a caller-visible read-before-write contract across agent + human and moves
it onto the feature branch.)
- Pros: no new state; GitHub's own concurrency control; identical for agent and human.
- Cons: per-file detection, no auto-merge (NG3 — we detect, not merge).
- **Chosen.** (B: app-level lock — rejected, needs presence we excluded. C: last-write-wins —
  rejected, clobbers the human edit G5 forbids.)

### 3.3 How in-chat approval executes (governance — G6/G7/NG5)
**Option A — read-only agent tool renders the card; the human's button click drives a backend
transition (chosen).** `workflow_request_approval` returns an `approval_request` payload and
mutates nothing; the FE renders the interactive card; Approve/Reject/Re-open POST to the hermes
**stage-transition** endpoint (FE → BFF → hermes), actor = `X-User-Id`.
- Pros: the agent *cannot* approve (no transition tool) — governance enforced by construction;
  the decision is an explicit authenticated call; clean audit.
- **Chosen.** (B: agent calls an "approve" tool — rejected; hands the agent the transition
  capability and turns the human decision into an LLM turn, violating NG5.)

### 3.4 Where the document-content view API sources content (read side)
**Option A — workflow-backend reads GitHub directly (chosen).** workflow-backend's new view API
calls the GitHub REST Contents API for `docs/features/<id>/<document>.md` on `feature/<id>`,
returning `{content, sha, url}`, and lists PRs for the branch for the PR-status read. It holds
a read-scoped `GITHUB_TOKEN`.
- Pros: one hop on the read path (hot path: every view + every preview refresh); no new
  cross-service call; `sha` comes free from the same read for the editor's optimistic lock;
  workspace-github-adapter untouched. A trusted backend holding a read token does not violate
  credential-isolation (that rule targets executors/agents, not backends).
- Cons: a second place that talks to GitHub (the adapter is the other). Acceptable for a
  read-only token.
- **Chosen.**

**Option B — delegate to workspace-github-adapter (the GitHub specialist).** Add a live
"content+sha for (feature, document, ref)" + "PR for branch" read API there; workflow-backend calls
it. Pros: centralizes GitHub access. Cons: extra service on the hot read path, a 4th touched
repo, more latency. **Rejected** for v3 (revisit if more services need live GitHub reads).

**Option C — store content in Postgres via richer sync.** Cons: staleness — the view would lag
the agent's just-committed change in the live authoring loop. **Rejected.**

### 3.5 Scope of stores (ts vs go)
**Chosen: `ts` only.** The stage-transition writes `status.yaml`; `go` features (Postgres state,
no `status.yaml`, deferred `workflow-db-mcp` write path) are explicitly **out of scope for v3**
and added later. Detecting/serving `go` is deliberately not built — not even a stub — to keep
the surface honest.

### 3.6 Editor technology (light edits — NG2)
**Option A — a plain Markdown `<textarea>` + reuse `MarkdownContent` for preview (chosen).**
Edit/Preview toggle (optionally side-by-side); preview is the existing renderer over the editor
text. Matches "light edits, not a full IDE editor"; no heavy dependency. **Chosen.** (B:
CodeMirror/Monaco — rejected as out-of-scope weight for NG2.)

---

## 4. Chosen Design

### 4.1 hermes-agent — document-commit pipeline `plugins/document_repo.py` + human-save endpoint [T1]

One write module used by the agent tool **and** the human Save endpoint (one write path, G3):

```python
# All calls use GITHUB_TOKEN against the management repo via the GitHub REST API.
def ensure_feature_branch(repo, feature_id, base_branch): ...   # create feature/<id> from base if absent (Git Refs API)
def read_document(repo, branch, path) -> {"content": str, "sha": str|None}:  # internal helper for the agent path's read-before-write
def write_document(repo, feature_id, base_branch, path, content, base_sha, message):
    branch = f"feature/{feature_id}"
    ensure_feature_branch(repo, feature_id, base_branch)
    # PUT contents with {message, content(b64), branch, sha=base_sha}
    #   HTTP 409 / 422 sha-mismatch -> raise StaleBaseError (surfaced as conflict — OQ1)
    pr = ensure_pr(repo, feature_id, base_branch)               # create-or-update; one PR/feature (G4)
    return {"commit_sha": ..., "pr": pr}
def ensure_pr(repo, feature_id, base_branch):                   # GET pulls?head=feature/<id>&base; else POST pulls
    # title: "documents(<feature_id>): product spec + technical design" (pr-create convention)
```

- **Agent tools — targeted edits + full rewrite (Canvas/Artifacts pattern, §Design templates).**
  Two write modes, mirroring how Canvas/Artifacts and Anthropic's `str_replace_based_edit_tool`
  work:
  - `workflow_edit_document` (**targeted edit**, the default for refinements): the agent emits
    `{document, edits: [{old_string, new_string}, ...]}`. The module `read_document`s the current content
    (read-before-write, G5), applies the replacements server-side, and `write_document`s the result.
    Small agent output (just the diff), minimal clobber surface.
  - `workflow_write_product_spec` / `workflow_write_technical_design` (**full rewrite**, retained
    by name for initial generation / major restructure): whole-document `read_document` → replace →
    `write_document`.
  Both `read_document` → `write_document` (commit to the feature branch, create/update the PR) and return
  `{ok, pr_url, commit_sha, conflict?}`. Replaces the direct-to-`main` PUT (fixes the
  no-direct-push violation). `hermes.artifact.saved` still fires on success.
- **Human Save endpoint** (`src/api/router.py`, `/api/v1`, `Depends(require_identity)`):
  ```
  PUT /api/v1/features/{feature_id}/document   body {document, content, base_sha}  -> {pr, commit_sha} | 409 conflict
  ```
  The `base_sha` is the one the FE got from **workflow-backend's view API** (§4.2) — the
  read-before-write contract holds across the read/write split. hermes serves **no document read**.

### 4.2 workflow-backend — document-content view API + PR status [T2]

New read endpoints (Gin, `/api/*`, `RequireBFFIdentity`), sourcing live content from GitHub:

```
GET /api/workspaces/:wid/features/:fid/documents/:type/content   -> {content, sha, url}
        # :type ∈ {product_spec, technical_design}; reads docs/features/<fid>/<file>.md on
        # feature/<fid> via GitHub Contents API; falls back to base branch / empty if absent.
GET /api/workspaces/:wid/features/:fid/documents/pr              -> {state: none|open|merged, url}
        # lists PRs for head=feature/<fid>
```

A small GitHub read client (new), `GITHUB_TOKEN` (read scope) in workflow-backend config. The
`sha` is returned so the editor can submit an optimistic-locked Save to hermes (§4.1). This is
the FE's single read path for document content, preview base, and edit-load.

### 4.3 hermes-agent — approval-request tool + ts stage-transition endpoint [T3]

**Read-only tool `workflow_request_approval`** (new `plugins/tools/approval.py`, added to
`_TOOLS`) — returns the card payload, mutates nothing:

```python
def handle(feature_id, stage, **_):   # stage ∈ {product_spec, technical_design}
    return {"ok": True, "approval_request": {"feature_id": feature_id, "stage": stage,
            "review_status": _current_review_status(feature_id, stage)}}
```
Its `description` says it surfaces an Approve/Reject control for a human and **does not approve**.
The payload rides out on the `hermes.tool.progress` completion event; the FE renders the card.

**Tools-list endpoint (for an accurate slash-command picker).** Today the FE picker
(`slash-command-picker.tsx`) is a **hardcoded, stale** array (names don't match the real tools;
`check_fn` gating ignored). Add a read-only gateway route that returns the live registry
definitions so the picker reflects what the agent can actually do (and auto-includes the new v3
tools without further FE edits):
```
GET /api/v1/tools  -> {tools: [{name, description}]}   # from registry.get_definitions, honoring each tool's check_fn
```
This reuses the existing Python registry (`vendor/hermes-agent/tools/registry.py`); no new
"skills" concept — "skills" in the chat picker == the agent's registered tools.

**Stage-transition endpoint** (commits `status.yaml` for `ts`, reusing §4.1's git-commit path so
`status.yaml` rides the same feature branch/PR as the documents):
```
POST /api/v1/features/{feature_id}/stage-transition
     body {stage, action: "approve"|"reject"|"reopen", comment?}    # actor = X-User-Id (from require_identity)
```
- **approve** → stage `review_status=approved`, `reviewed_by=X-User-Id`, `reviewed_at=now`,
  append `review_history`, advance `feature_status`/`current_stage`/`next_action`, append
  top-level `history` (mirrors `approve-feature`).
- **reject** → `review_status=rejected` + comment + history (mirrors `reject-feature`).
- **reopen** → move the stage back, **preserve artifacts, set revalidation flags** (mirrors
  `set-feature-stage`) — the G9 rollback.
- v3 serves **`ts` only**; `go` is out of scope (§3.5) — not stubbed.

> Actor note: `X-User-Id` is the OAuth user id, not necessarily the `GIT_AUTHOR_EMAIL` the CLI
> skills record. T3 stores `X-User-Id` (optionally resolved to an email via user-service) — a
> minor reconciliation flagged in §5.

### 4.4 digital-factory-ui — edit + preview + PR indicator [T4]

In `FeatureIDEDocsPanel` / `FeatureDocumentPanel` (the right documents panel):
- **View / Edit toggle.** Both view and edit load content from **workflow-backend's view API**
  (§4.2) `GET …/documents/:type/content` → `{content, sha, url}` (replacing the
  `/api/content/fetch` GitHub-URL path). Edit shows a `<textarea>` (source of truth) with a
  **Preview** toggle (and optional split) running the text through the existing `MarkdownContent`
  (NG4 — preview only).
- **Save** → hermes `PUT …/document {document, content, base_sha: sha}` (the `sha` came from the view API).
  Success → exit Edit, refetch content + PR status. **409** → "This document changed since you
  opened it" + Reload (OQ1 — detect + reload, no silent overwrite). **Discard** + dirty-state +
  unsaved-changes nav guard.
- **PR-status indicator** — workflow-backend `GET …/documents/pr` → none / open (link) / merged;
  re-fetched after save and on `hermes.artifact.saved`.
- **Live preview during agent generation** — reuse the existing `hermes.artifact.saved` →
  `onArtifactSaved` → React Query invalidation so the rendered document updates as the agent commits
  (G2). New service fns: read (content + PR) in `src/services/workflow-backend/`, Save in
  `src/services/hermes-agent/`.

### 4.5 digital-factory-ui — interactive tool-call cards [T5]

A **generative-UI renderer registry** (the AI SDK "tool result → component" pattern, §4b) in the
chat tool-call path (`message-thread.tsx` `ToolCallRow`, today plain chips), keyed by tool name +
the completion output:
- **`workflow_request_approval`** → an **Approval card**: stage, current review_status,
  **Approve / Reject (comment) / Re-open** buttons → `POST …/stage-transition` (FE → BFF →
  hermes). On success, refresh the explorer stage/approval checkmarks + PR indicator.
- **`workflow_edit_document` / `workflow_write_product_spec` / `workflow_write_technical_design`** → a
  **Document-edit card**: which document changed, a summary of the targeted edits (or "rewritten"), and the
  PR link (and conflict state if `conflict`).
- Unknown tools keep the existing chip rendering (backward compatible).

**Slash-command picker — fetch instead of hardcode.** Replace the hardcoded `COMMANDS` array in
`slash-command-picker.tsx` with a fetch of hermes `GET /api/v1/tools` (§4.3), so the picker lists
the live, available tools (including the new v3 ones) with their descriptions, and stays correct
as tools change or are gated off.

### 4.6 End-to-end flow (ts feature)
1. User chats → agent `read_document` then `workflow_write_product_spec` → commit on `feature/<id>`,
   PR created/updated → `hermes.artifact.saved` → documents panel refetches from **workflow-backend
   view API** + PR indicator refresh.
2. User light-edits → load `{content, sha}` from **workflow-backend** `GET …/documents/:type/content`
   → Save to **hermes** `PUT …/document {base_sha:sha}` → same PR updated. The next agent edit re-reads
   first, so it cannot clobber the manual change (409 on a stale sha).
3. Agent calls `workflow_request_approval` → Approval card. User clicks **Approve** →
   `POST …/stage-transition {action:"approve"}` → hermes updates `status.yaml` on the feature
   branch (same PR), feature → `in_tdd`. The PR is **not** merged (G8).
4. "Re-open the spec" → Re-open card/button → `action:"reopen"` → reverse transition +
   revalidation (G9).

### 4.7 hermes-agent — skills subsystem (implements G10) [T6]

hermes has **no skill concept** today (only tools + hooks). G10 ("stack-aware technical design")
needs the agent to load the `agent-workflow` skill content. Add a lightweight
**progressive-disclosure skills subsystem** — the Anthropic Skills pattern, implemented as a hermes
tool since there's no native one:

- **Skill index.** At startup, read the `description` frontmatter from each loadable SKILL.md:
  all `claude/technical_skills/*/SKILL.md` (pure knowledge — `typescript-best-practices` etc. carry
  **0** tool/bash/git references) plus the **authoring** skills `claude/workflow_skills/{tech-lead,
  init-feature}/SKILL.md`. Build a `{name, description, path}` index.
- **System-prompt injection.** The `pre_llm_call` hook (`plugins/hooks.py`) injects the skill
  *descriptions* (name + one-line) so the agent knows what's available without paying for full
  bodies. For the **technical-design** stage, resolve the feature's stack from its touched repos
  (`workspace.yaml`) and surface the matching `technical_skills` descriptions prominently (G10).
- **`load_skill(name)` tool** (`plugins/tools/skills.py`, added to `_TOOLS`). Returns the full
  `SKILL.md` plus its reference files on demand (e.g. `nextjs-best-practices`' 20 sub-documents,
  `typescript-best-practices/references/`). Read-only. Appears in `GET /api/v1/tools` and the slash
  picker automatically (§4.3).

**Boundaries (from the skill-capability analysis):**
- **Load** only the *knowledge* + *authoring* buckets. **Do not** load the *mutation* skills
  (`approve-feature`/`reject-feature`/`set-feature-stage`) — those are reimplemented as tools (T3);
  loading their text would be redundant. **Do not** load the *execution* skills
  (`start-implementation`, `review-pr`, `browser-qa-frontend`, `sync-workspace-rules`,
  `init-workspace`, …) — they assume `bash`/`git`/local-checkout/tests/CI the gateway does not have
  (`start-implementation` has 25 such references); driving them is the executor / Managed-Agents
  layer, out of scope for v3.
- **Adaptation:** authoring SKILL.md text references Claude Code tools (`Read`/`Edit`/`git`). The
  agent maps those steps onto hermes's document tools (`workflow_edit_document` / write / `pr-create`-backed
  commit); the loaded text is *guidance*, not a literal tool script.

**Dependency — how hermes gets the files.** The skills live in the `agent-workflow` (`workflow`)
repo, not in hermes. Resolve the source: bundle a snapshot into the hermes image at build, or fetch
the `workflow` repo's `claude/` tree via the GitHub API at startup (using the existing
`GITHUB_TOKEN`). Flagged as OQ5.

---

## 4b. Design templates (what v3 borrows from OpenAI Canvas, Claude Artifacts, the AI SDK)

v3 is structurally the "edit-a-document-alongside-chat" pattern that OpenAI **Canvas** and Claude
**Artifacts** popularised, with **generative-UI** tool rendering and **human-in-the-loop**
approval from the AI SDK / Anthropic tool-use playbook. Rather than invent interaction models, v3
adopts these established templates surface-by-surface:

| v3 surface | Template | What we borrow |
|---|---|---|
| Documents panel + chat (right-panel document, chat drives it, live preview) | **OpenAI Canvas / Claude Artifacts** split-view | Generate → render → describe change → revise in place; never leave the chat. v3's preview panel (§4.4) is the canvas/artifact panel. |
| Agent document edits | **Canvas targeted-edit-vs-rewrite** + Anthropic **`str_replace_based_edit_tool`** | Targeted `old_string→new_string` edits for refinements, full rewrite for initial/major changes (§4.1). Smaller output, less clobber surface than whole-document regeneration. |
| Manual edits + preview | **Canvas direct editing** | Click-in `<textarea>` editing coexists with chat-driven editing; one document, one write path (G3). |
| Versioning | **Canvas / Artifacts versions** | Git is the version store — every edit is a commit on the feature branch; the PR is the version history (G4). |
| Tool-call cards (approval / document-edit) | **AI SDK generative UI** (tool result → React component) | A tool-name → component registry renders tool results as interactive cards instead of raw chips (§4.5). |
| In-chat approval | **AI SDK `needsApproval` / Anthropic `always_ask` → `tool_confirmation`** | The approval card is the human-in-the-loop confirmation: allow/deny + message == approve/reject + comment (§4.3). |

**Adaptation note — why not "pure" gated-tool HITL.** The textbook HITL flow (agent calls the real
mutating tool; the runtime *pauses* the loop and awaits a confirmation event before executing —
Anthropic Managed Agents' `always_ask` + `user.tool_confirmation`) requires a confirmation
round-trip in the agent runtime. The current hermes gateway is a custom OpenAI-style SSE service
with **no pause/confirm round-trip** (§1). So v3 applies the *same pattern* with the pieces it has:
a **read-only `workflow_request_approval` tool renders the confirmation card** (generative UI), and
the human's allow/deny is a **separate authenticated backend call** (§4.3) — which also keeps the
governance property that the agent has no tool that can mutate review state (NG5). If the gateway
later gains a confirmation round-trip (or moves to Managed Agents), this can collapse into the
pure gated-tool form with no FE change.

**Live preview during generation (Canvas/Artifacts live update).** Canvas and Artifacts stream the
document *as it is written*, not only after a save. v3's baseline refetches on
`hermes.artifact.saved` (§4.4), which updates the preview once per commit. As an **enhancement**
(not required for v1 of v3): stream the generated/edited document text into the preview live — either by
parsing the agent's `workflow_edit_document` arguments off the existing `hermes.tool.progress` stream,
or by adding a dedicated `hermes.artifact.delta` SSE event — so the user watches the document take shape
token-by-token before the commit lands. Flagged as OQ4.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| `workflow-bff` generic proxy forwards new hermes + workflow-backend routes w/ identity | Existing | ✅ prefix proxy + `X-User-Id` injection + SSE pass-through; now registered in `workspace.yaml` | No — **no BFF change needed** |
| New hermes routes inherit `require_identity` (service token + `X-User-Id`) | Existing | ✅ `src/api/identity.py` | No |
| New workflow-backend routes inherit `RequireBFFIdentity` | Existing | ✅ `cmd/api/api.go:87` | No |
| `GITHUB_TOKEN` in hermes, push + PR scope on management repo | Existing | ✅ already writes documents there | No |
| `GITHUB_TOKEN` (read scope) in workflow-backend for the view API | **New env** | ⚠️ workflow-backend has no GitHub client today | T2 — add a small GitHub read client + token |
| GitHub Contents API blob-`sha` 409-on-stale | External | ✅ standard behavior; artifacts.py already fetches sha | No — it *is* the concurrency primitive |
| `feature/<feature_id>` branch on management repo | Created by pipeline | created on first write; view API falls back to base/empty before then | No |
| `hermes.artifact.saved` → `onArtifactSaved` refetch | Existing | ✅ `agent-chat-panel.tsx` / `feature-workbench.tsx` | No — reused for live preview |
| `MarkdownContent` renderer for preview | Existing | ✅ `src/utils/markdown.tsx` | No |
| Actor identity = `X-User-Id` (OAuth id) vs `GIT_AUTHOR_EMAIL` (skills) | Reconciliation | ⚠️ different identifiers | Minor — store `X-User-Id`, optionally resolve to email via user-service |
| `go`-feature approval (Postgres / `workflow-db-mcp`) | External feature | ⛔ deferred placeholder — not built; `go` schema for stage-review unconfirmed | **Out of scope for v3** — `ts` only (per product owner); a clean follow-on |

**Out of scope (not blocking v3):** the `go`-feature approval path (Postgres state via the
deferred `workflow-db-mcp`, plus the unconfirmed "do `go` features store stage-review state"
question) — explicitly deferred; v3 ships the **`ts` path fully** and does not stub `go`.

---

## 6. Parallelization / Blocking Analysis

Anticipated decomposition (one repo per task). Task **files** are produced in Phase 2 after this
design is approved; this is the planning view. **Three repos are touched: hermes-agent (write +
chat), workflow-backend (read/view), digital-factory-ui (UI)** — workflow-bff and
workspace-github-adapter need no change.

```
T1: hermes-agent — plugins/document_repo.py (feature-branch commit + create/update PR; read-before-write)
                   + reimplement artifacts.py write tools + PUT /api/v1/features/{fid}/document (human save)
  └── Can begin now — no blockers

T2: workflow-backend — document-content view API GET .../documents/:type/content {content,sha,url}
                       + GET .../documents/pr {state,url}  (live GitHub read client + token)
  └── Can begin now — reads GitHub directly; independent of hermes

T6: hermes-agent — skills subsystem (G10): skill index + load_skill tool + description injection
                   in pre_llm_call (technical_skills + tech-lead/init-feature authoring guidance)
  └── Can begin now — additive plugin/hook; independent of T1/T3
  └── load_skill auto-appears in GET /api/v1/tools (T3) and the slash picker (T5)

  T3: hermes-agent — workflow_request_approval (read-only tool) + POST /api/v1/.../stage-transition
                     (ts status.yaml via document_repo's commit path)
      └── BLOCKED on T1 (stage-transition reuses document_repo's git-commit path for status.yaml)

  T4: digital-factory-ui — FeatureIDEDocsPanel edit + preview + Save/Discard + dirty-guard
                           + PR indicator; read fns (workflow-backend), save fn (hermes)
      └── Can begin UI now — preview reuses MarkdownContent; contracts defined in §4.1/§4.2
      └── BLOCKED (integration) on T1 (save) + T2 (content/PR view)
      │
      T5: digital-factory-ui — interactive tool-call cards (approval + document-edit) in message-thread
          └── BLOCKED on T3 (Approve/Reject/Re-open call POST .../stage-transition; consumes the
              approval_request payload contract from T3)
          └── lands after T4 on the FE branch (T4 = documents panel, T5 = chat thread — minimal overlap)

Waves:
  Wave 1 (parallel): T1, T2, T6      (hermes write path + workflow-backend read path + skills subsystem — independent)
  Wave 2 (parallel): T3, T4          (T3 dep T1; T4 integrates T1+T2)
  Wave 3:            T5               (dep T3; after T4 on the FE branch)
```

---

## 7. Repository Impact

| Repo (`workspace.yaml` id) | Task | Changes | Why |
|---|---|---|---|
| `hermes-agent` | T1 | new `plugins/document_repo.py`; new `workflow_edit_document` targeted-edit tool + reimplement `plugins/tools/artifacts.py` full-rewrite tools; `src/api/router.py` `PUT /api/v1/features/:fid/document` | targeted (str_replace) + full-rewrite edits, feature-branch commit + create/update PR + read-before-write; human Save (fixes direct-to-main) |
| `workflow-backend` | T2 | new GitHub read client + `GITHUB_TOKEN`; `GET …/documents/:type/content`, `GET …/documents/pr` | **document view/read API** (content+sha + PR status) — the FE read path |
| `hermes-agent` | T3 | new `plugins/tools/approval.py` + `_TOOLS` entry; `src/api/router.py` `POST …/stage-transition` (ts `status.yaml`) **+ `GET /api/v1/tools`** (registry-backed tools list) | in-chat approval affordance + ts lifecycle write + accurate slash picker |
| `digital-factory-ui` | T4 | `FeatureIDEDocsPanel`/`FeatureDocumentPanel` edit + preview + PR indicator; read fns in `src/services/workflow-backend/`, save fn in `src/services/hermes-agent/` | editable documents + preview + PR status |
| `digital-factory-ui` | T5 | `message-thread.tsx` tool-call renderer registry: approval card + document-edit card; **`slash-command-picker.tsx` fetches `GET /api/v1/tools`** instead of the hardcoded array | interactive tool-call rendering + live slash picker |
| `hermes-agent` | T6 | new `plugins/skills/` index + `plugins/tools/skills.py` (`load_skill`) + `_TOOLS` entry; `plugins/hooks.py` description injection (stack-aware for tech-design) | **skills subsystem (G10)** — load technical_skills + tech-lead/init-feature authoring guidance |
| `workflow-bff` | — | **none** (generic proxy forwards new routes automatically) | — |
| `workspace-github-adapter` | — | **none** (workflow-backend reads GitHub directly; sync path untouched) | — |

> `workflow-db-mcp` and the `go` approval path are **out of scope** for v3 (deferred).

---

## 8. Validation and Release Impact

### Testing
- **T1 (hermes write)** — read-before-write: stale `sha` PUT → `StaleBaseError`/409 surfaced
  (not overwritten); new-file path (`sha=None`); `ensure_pr` create-vs-reuse (one PR/feature);
  the write targets `feature/<id>`, never `main`; `PUT …/document` round-trips + enforces
  `require_identity`.
- **T2 (workflow-backend read)** — `GET …/documents/:type/content` returns `{content, sha, url}`
  from the feature branch; falls back to base/empty when the branch/file is absent;
  `GET …/documents/pr` maps none/open/merged; routes enforce `RequireBFFIdentity`.
- **T3 (hermes approval)** — `workflow_request_approval` writes nothing; stage-transition applies
  approve/reject/reopen matching the skills (review_status, history, revalidation); actor =
  `X-User-Id`; operates on `ts` features (`status.yaml`). `GET /api/v1/tools` returns the live
  tool list and **omits a tool whose `check_fn` is false** (e.g. gitnexus/rag when unset).
- **T4 (FE editor)** — loads `{content, sha}` from the view API; Save posts the sha to hermes;
  409 → reload affordance; dirty-guard blocks nav; PR indicator renders three states; preview
  re-renders on `hermes.artifact.saved`.
- **T5 (FE cards)** — approval card renders from the `approval_request` output;
  Approve/Reject/Re-open call the stage-transition endpoint via the BFF; unknown tools still
  render as chips; the slash picker renders the list returned by `GET /api/v1/tools` (no longer
  the hardcoded array).
- **T6 (skills subsystem)** — the index reads every loadable `SKILL.md` description; `load_skill`
  returns the full body + reference files and errors cleanly on an unknown/non-loadable skill
  (mutation/execution skills are not indexed); the `pre_llm_call` hook injects descriptions and,
  for the technical-design stage, surfaces the stack-matched `technical_skills`; `load_skill`
  appears in `GET /api/v1/tools`.
- Each repo's full suite + lint/type-check before its PR (CLAUDE.md pre-push rules): Python
  (hermes), Go (workflow-backend), and the JS/TS toolchain (digital-factory-ui).

### Migration / Config
- **No DB schema change.** New env: `GITHUB_TOKEN` (read scope) in workflow-backend for the view
  API. No new heavy FE dependency.
- No `workspace.yaml` change required (`workflow-bff` already registered; v3 touches no BFF code).

### Rollout
- Additive. The one semantic shift is the agent write-tool behavior (direct-to-`main` →
  feature-branch + PR) — a **fix** of a rule violation, not a regression.
- The document read path moves from the FE's `/api/content/fetch` GitHub-URL hack to the
  workflow-backend view API; ship T2 + T4 together so the FE switches cleanly.
- `go`-feature approval is **out of scope** (deferred), so no `go` feature is affected.

### Backward compatibility
- `workflow_write_product_spec` / `workflow_write_technical_design` keep their names + arg shape
  but now read-before-write, commit to `feature/<id>`, and open/update a PR (returning `pr_url`).
  Callers that assumed a bare commit to the default branch now get a PR — the intended change
  (NG7). Document in the PR body.
- SSE envelope, gateway auth, BFF proxy, existing workflow-backend routes, and the v2 workbench
  shell are all unchanged.

## Open Questions

- **OQ1 — Stale-base resolution UX.** On a 409 (the GitHub blob `sha` moved since the editor/agent
  read it), what does the FE do: reload-and-retry, present a diff to choose, or warn-and-let-the-
  user-decide? v3 does detection, not auto-merge (NG3). Targeted `str_replace` edits narrow the
  conflict window but don't eliminate it.
- **OQ2 — Rollback transition definition.** Which exact reverse transition(s) implement "re-open an
  approved stage," and how do they set the `revalidation` flags in `status.yaml`?
- **OQ3 — Actor identity.** `X-User-Id` (OAuth id) vs the `GIT_AUTHOR_EMAIL` the CLI skills record
  as `reviewed_by`. Store the id, or resolve it to an email via user-service?
- **OQ4 — Live preview during generation (Canvas/Artifacts template, §4b).** Ship the
  refetch-on-`hermes.artifact.saved` baseline first, or invest in streaming the document into the
  preview token-by-token (parse `hermes.tool.progress` args, or add a `hermes.artifact.delta`
  event)? Enhancement, not required for v1.
- **OQ5 — Skill file source for the skills subsystem (T6, §4.7).** How does hermes obtain the
  `agent-workflow` `claude/` skill files — bundle a snapshot into the image at build, or fetch the
  `workflow` repo tree via the GitHub API at startup? Bundling is simpler but goes stale; fetching
  is live but adds a startup dependency.

## Reference
- Design templates: OpenAI Canvas (`openai.com/index/introducing-canvas`), Claude Artifacts,
  Vercel AI SDK generative UI + `needsApproval` HITL (`ai-sdk.dev`), Anthropic
  `str_replace_based_edit_tool` + `always_ask`/`tool_confirmation` (claude-api skill).
- Product spec: `docs/features/m3-agent-chat-v3/product-spec.md`
- Live code verified 2026-06-13:
  - `workflow-bff`: `internal/app/api/handler/proxy/{routing.go,proxy_handler.go}`, `configs/config.yaml`
  - `hermes-agent`: `src/api/{router.py,identity.py}`, `src/app.py`, `src/streaming/sse.py`,
    `plugins/{__init__.py,db.py,hooks.py}`, `plugins/tools/artifacts.py`
  - `workflow-backend`: `cmd/api/api.go`, `internal/authmw/*`, `internal/handler/workspace.go`,
    `internal/domain/dto.go`
  - `digital-factory-ui`: `src/components/features/feature-workbench.tsx`,
    `src/components/features/feature-ide-docs-panel.tsx`,
    `src/components/board/feature-document-panel.tsx`, `src/components/agent-chat/*`,
    `src/services/{hermes-agent,workflow-backend}/*`, `src/constants/axios.ts`
- Storage split: `docs/features/workflow-db/product-spec.md`,
  `docs/features/workflow-db-mcp/product-spec.md` (deferred go write path)
- Lifecycle skills: `approve-feature`, `reject-feature`, `set-feature-stage`; `pr-create`;
  management-repo "no direct push to main" + feature-branch rules in `CLAUDE.md`.
