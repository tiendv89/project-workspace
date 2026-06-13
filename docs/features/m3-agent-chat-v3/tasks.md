# m3-agent-chat-v3 — Task Breakdown

**Feature status:** `in_tdd` | **Stage:** `tasks` (awaiting approval)
Machine-readable state lives in `tasks/T<n>.yaml`. This file is narrative only.

## Index

| ID  | Wave | Title                                                                 | Depends on |
|-----|------|-----------------------------------------------------------------------|------------|
| T1  | 1    | hermes-agent: document write pipeline + edit tools + human-save route | —          |
| T2  | 1    | workflow-backend: document view/read API (content + PR status)        | —          |
| T6  | 1    | hermes-agent: skills subsystem (load technical_skills + authoring)    | —          |
| T3  | 2    | hermes-agent: approval tool + stage-transition + tools-list endpoint  | T1         |
| T4  | 2    | digital-factory-ui: document edit + preview + PR indicator            | T1, T2     |
| T5  | 3    | digital-factory-ui: interactive tool-call cards + live slash picker   | T3         |

> `go`-feature approval path is **out of scope** (ts only — deferred to `workflow-db-mcp`).
> `workflow-bff` and `workflow-backend` chat need **no change** (generic proxy / chat proxy removed).

---

## T1 — hermes-agent: document write pipeline + edit tools + human-save route

### Description
Replace v1's direct-to-`main` GitHub Contents PUT with a document-commit pipeline, and add
targeted + full-rewrite edit tools plus a human-save endpoint. Implements technical design §4.1
(and the Canvas/Artifacts targeted-edit template, §4b).

- New `plugins/document_repo.py`:
  - `ensure_feature_branch(repo, feature_id, base_branch)` — create `feature/<feature_id>` from
    the base branch head if absent (Git Refs API).
  - `read_document(repo, branch, path) -> {content, sha|None}` — GitHub Contents API GET (`?ref=`);
    404 → `sha=None` (new file). This is the read-before-write source for the agent path (G5).
  - `write_document(repo, feature_id, base_branch, path, content, base_sha, message)` — PUT to
    `feature/<feature_id>` with `sha=base_sha`; HTTP 409 / 422 sha-mismatch → raise
    `StaleBaseError` (surfaced as a conflict); then `ensure_pr` (create-or-update **one PR per
    feature**), return `{commit_sha, pr}`.
  - `ensure_pr(repo, feature_id, base_branch)` — find open PR `head=feature/<feature_id>` else
    create (title `docs(<feature_id>): product spec + technical design`).
- New **targeted-edit tool** `workflow_edit_document` (`plugins/tools/`): args
  `{doc, edits: [{old_string, new_string}, ...]}`; `read_document` → apply replacements
  server-side → `write_document`. Default path for refinements (small diff, minimal clobber).
- **Reimplement** the full-rewrite handlers `workflow_write_product_spec` /
  `workflow_write_technical_design` (`plugins/tools/artifacts.py`) to use `document_repo`
  (read → replace → write) instead of the direct Contents PUT. Keep tool names. Return
  `{ok, pr_url, commit_sha, conflict?}`. `hermes.artifact.saved` still fires on `ok`.
- **Human-save endpoint** `PUT /api/v1/features/{feature_id}/document` (`src/api/router.py`,
  `Depends(require_identity)`): body `{doc, content, base_sha}` → `document_repo.write_document`;
  409 → structured conflict. `base_sha` comes from workflow-backend's view API (T2).

Touches only `hermes-agent`. Fixes the live "no direct push to main" violation by committing to
`feature/<feature_id>` and opening a PR.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] `document_repo.py`: `ensure_feature_branch`, `read_document`, `write_document`, `ensure_pr`
- [ ] `write_document` raises `StaleBaseError` on 409/422 sha-mismatch (no silent overwrite)
- [ ] `ensure_pr` is create-or-update — exactly one open PR per feature
- [ ] `workflow_edit_document` targeted tool: applies `[{old_string,new_string}]` against current content
- [ ] Reimplement `workflow_write_product_spec` / `_technical_design` to use `document_repo`; commit targets `feature/<id>`, never `main`
- [ ] `PUT /api/v1/features/{fid}/document` human-save route under `require_identity`
- [ ] Unit: stale-sha PUT surfaces conflict; new-file path (`sha=None`); `ensure_pr` reuse vs create
- [ ] Tests + lint pass; PR via `pr-create`

---

## T2 — workflow-backend: document view/read API (content + PR status)

### Description
Add the document **view/read** API the FE uses for rendering, preview, and edit-load. hermes owns
writes; workflow-backend owns reads. Implements technical design §4.2.

- New small **GitHub read client** (Go) + read-scoped `GITHUB_TOKEN` in config.
- `GET /api/workspaces/:wid/features/:fid/documents/:type/content` → `{content, sha, url}` —
  reads `docs/features/<fid>/<file>.md` on `feature/<fid>` via the Contents API; falls back to the
  base branch / empty when the branch or file does not yet exist. `:type ∈ {product_spec,
  technical_design}`. The `sha` lets the FE editor submit an optimistic-locked save to hermes (T1).
- `GET /api/workspaces/:wid/features/:fid/documents/pr` → `{state: none|open|merged, url}` — lists
  PRs for `head=feature/<fid>`.
- Routes register under the existing `/api` group (`authmw.RequireBFFIdentity`).

Touches only `workflow-backend`. Replaces the FE's `/api/content/fetch` GitHub-web-URL path.

### Required skills
- go-best-practices
- backend-engineer

### Subtasks
- [ ] GitHub read client (Contents API GET on a ref; list PRs by head) + `GITHUB_TOKEN` config
- [ ] `GET …/documents/:type/content` → `{content, sha, url}`; feature-branch read with base/empty fallback
- [ ] `GET …/documents/pr` → `{state, url}` mapping none/open/merged
- [ ] Register both under `RequireBFFIdentity`
- [ ] Unit: content read (present / branch-absent fallback); pr-status mapping
- [ ] Tests + `golangci-lint` clean; PR via `pr-create`

---

## T6 — hermes-agent: skills subsystem (load technical_skills + authoring guidance)

### Description
Give hermes a progressive-disclosure skills subsystem (it has none today) so the agent can load
the `agent-workflow` skill content. Implements technical design §4.7 and goal G10.

- **Skill index** (`plugins/skills/`): at startup read the `description` frontmatter from each
  loadable `SKILL.md` — all `claude/technical_skills/*/SKILL.md` plus the authoring skills
  `claude/workflow_skills/{tech-lead,init-feature}/SKILL.md`. Build a `{name, description, path}`
  index. **Do not** index the mutation skills (`approve-feature`/`reject-feature`/
  `set-feature-stage` — they are tools, T3) or the execution skills (`start-implementation`,
  `review-pr`, `browser-qa-frontend`, `sync-workspace-rules`, `init-workspace`, … — they need a
  shell/git the gateway lacks).
- **`load_skill(name)` tool** (`plugins/tools/`, added to `_TOOLS`): returns the full `SKILL.md`
  plus its reference files (e.g. `nextjs-best-practices`' sub-docs, `*/references/`). Read-only;
  appears in `GET /api/v1/tools` (T3) and the slash picker (T5) automatically.
- **System-prompt injection** (`plugins/hooks.py` `pre_llm_call`): inject the skill descriptions;
  for the **technical-design** stage, resolve the feature's stack from its touched repos
  (`workspace.yaml`) and surface the matching `technical_skills` prominently.
- **Skill-file source (OQ5):** resolve how hermes obtains the `agent-workflow` `claude/` files —
  bundle a snapshot at image build, or fetch the `workflow` repo tree via the GitHub API at
  startup (using `GITHUB_TOKEN`). Pick one and document it.

Touches only `hermes-agent`.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Resolve + implement the skill-file source (bundle vs GitHub fetch) — OQ5
- [ ] Skill index reads descriptions from technical_skills + tech-lead/init-feature only
- [ ] `load_skill(name)` tool returns full body + reference files; errors on unknown/non-loadable
- [ ] Register `load_skill` in `_TOOLS`
- [ ] `pre_llm_call` injects descriptions; stack-matched surfacing for the technical-design stage
- [ ] Unit: index excludes mutation/execution skills; `load_skill` round-trip; stack matching
- [ ] Tests + lint pass; PR via `pr-create`

---

## T3 — hermes-agent: approval tool + stage-transition + tools-list endpoint

### Description
Surface in-chat approval and write the `ts` lifecycle transition; expose the live tool list for an
accurate slash picker. Implements technical design §4.3 (HITL approval template, §4b).

- **Read-only tool `workflow_request_approval`** (`plugins/tools/approval.py`, added to `_TOOLS`):
  args `{feature_id, stage∈{product_spec,technical_design}}`; returns
  `{approval_request: {feature_id, stage, review_status}}`. Mutates nothing — the FE renders the
  confirmation card; the agent has no tool that writes review state (governance).
- **Stage-transition endpoint** `POST /api/v1/features/{feature_id}/stage-transition`
  (`Depends(require_identity)`): body `{stage, action: approve|reject|reopen, comment?}`;
  `actor = X-User-Id`. Commits the `status.yaml` change via the T1 commit path (rides the same
  feature branch / PR):
  - approve → `review_status=approved` + reviewed_by/at + history + advance feature; **does not
    merge** the PR.
  - reject → `review_status=rejected` + comment + history.
  - reopen → move the stage back, preserve artifacts, set revalidation flags (G9 rollback).
  - mirrors `approve-feature` / `reject-feature` / `set-feature-stage`. **ts only** — a feature
    with no `status.yaml` is rejected (go path deferred).
- **`GET /api/v1/tools`** → `{tools: [{name, description}]}` from the registry, honoring each
  tool's `check_fn` (gated-off tools omitted). Feeds the FE slash picker (T5).

Touches only `hermes-agent`. Depends on T1 (reuses `document_repo`'s git-commit path for
`status.yaml`).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] `workflow_request_approval` read-only tool (returns payload, writes nothing) + `_TOOLS`
- [ ] `POST …/stage-transition` apply approve/reject/reopen to `status.yaml` via T1 commit path; actor = `X-User-Id`
- [ ] approve advances feature + does NOT merge the PR; reopen sets revalidation flags
- [ ] reject a feature with no `status.yaml` (go) — out of scope
- [ ] `GET /api/v1/tools` registry list honoring `check_fn`
- [ ] Unit: approval tool writes nothing; transition mutations match the skills; tools-list omits gated tools
- [ ] Tests + lint pass; PR via `pr-create`

---

## T4 — digital-factory-ui: document edit + preview + PR indicator

### Description
Make the documents panel editable with live preview and surface the PR status. Implements technical
design §4.4 (Canvas/Artifacts editable-panel template, §4b).

- In `FeatureIDEDocsPanel` / `FeatureDocumentPanel`: **View / Edit toggle**. Both load
  `{content, sha}` from workflow-backend's view API (T2) `GET …/documents/:type/content` (replacing
  the `/api/content/fetch` GitHub-URL path). Edit shows a `<textarea>` (source of truth) with a
  **Preview** toggle running the text through the existing `MarkdownContent` renderer.
- **Save** → hermes `PUT …/document {doc, content, base_sha: sha}` (T1). Success → exit Edit,
  refetch content + PR status. **409** → "This document changed since you opened it" + Reload
  affordance (detect + reload, no silent overwrite). **Discard** + dirty-state + unsaved-changes
  nav guard.
- **PR-status indicator** — workflow-backend `GET …/documents/pr` → none / open (link) / merged;
  re-fetched after save and on `hermes.artifact.saved`.
- Live preview during agent generation reuses the existing `hermes.artifact.saved` →
  `onArtifactSaved` → React Query invalidation.
- New service fns: read (content + PR) in `src/services/workflow-backend/`; save in
  `src/services/hermes-agent/`.

Touches only `digital-factory-ui`. Depends on T1 (save) + T2 (content/PR read).

### Required skills
- nextjs-best-practices
- frontend-engineer
- heroui-react

### Subtasks
- [ ] View/Edit toggle in `FeatureIDEDocsPanel`/`FeatureDocumentPanel`; load `{content, sha}` from T2
- [ ] `<textarea>` editor + Preview via `MarkdownContent`; dirty-state + unsaved-changes guard
- [ ] Save → hermes `PUT …/document` with `base_sha`; 409 → reload affordance; Discard
- [ ] PR-status indicator from `…/documents/pr`; refetch on `hermes.artifact.saved`
- [ ] Service fns: read in `services/workflow-backend/`, save in `services/hermes-agent/`
- [ ] Component tests: edit/preview/save/409/dirty-guard/PR-indicator
- [ ] Tests + lint pass; PR via `pr-create`

---

## T5 — digital-factory-ui: interactive tool-call cards + live slash picker

### Description
Render tool calls as interactive cards (generative UI) and drive the slash picker from the live
tool list. Implements technical design §4.5 / §4.7 (AI SDK generative-UI template, §4b).

- **Generative-UI renderer registry** in the chat tool-call path (`message-thread.tsx`
  `ToolCallRow`, today plain chips), keyed by tool name + completion output:
  - `workflow_request_approval` → **Approval card**: stage, current `review_status`,
    **Approve / Reject (comment) / Re-open** buttons → `POST …/stage-transition` (FE → BFF →
    hermes, T3). On success, refresh the explorer stage/approval checkmarks + PR indicator.
  - `workflow_edit_document` / `workflow_write_product_spec` / `workflow_write_technical_design` →
    **Document-edit card**: which document changed, a summary of the edits (or "rewritten"), and
    the PR link (conflict state if `conflict`).
  - Unknown tools keep the existing chip rendering (backward compatible).
- **Slash picker** — `slash-command-picker.tsx` fetches `GET /api/v1/tools` (T3) instead of the
  hardcoded array, so it lists the live, available tools (including the new ones) with descriptions.

Touches only `digital-factory-ui`. Depends on T3 (approval payload + stage-transition + tools-list).
Soft-ordered after T4 on the FE branch (different files — minimal overlap).

### Required skills
- nextjs-best-practices
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Renderer registry in `message-thread.tsx` keyed by tool name + output
- [ ] Approval card: Approve/Reject(comment)/Re-open → `POST …/stage-transition`; refresh stage + PR indicator
- [ ] Document-edit card: doc + edits summary + PR link (+ conflict state)
- [ ] Unknown tools still render as chips (backward compatible)
- [ ] `slash-command-picker.tsx` fetches `GET /api/v1/tools` (drop hardcoded array)
- [ ] Component tests: cards render from output; buttons call the endpoint; picker renders fetched list
- [ ] Tests + lint pass; PR via `pr-create`
