# Product Specification

## Feature
- Feature ID: `m3-agent-chat-v3`
- Title: Agent Chat v3 — Conversational Document Authoring, PR-tracked Commits, and In-UI Approval

## Background

The M3 agent-chat line turns the digital-factory-ui into a place where a human and the
hermes-agent co-author a feature's artifacts through conversation.

- **v1 (`m3-agent-chat`)** shipped the chat panel and the first generation loop: the agent
  reads workspace context and writes `product-spec.md` / `technical-design.md` into the
  management repo via workflow skills.
- **v2 (`m3-agent-chat-v2`)** added persistent session history, context-rich agent tools
  (live tasks, GitNexus, RAG), and a three-panel IDE-style layout: left = task/feature
  status (Jira-like), center = artifact content, right = agent chat.

**v3 makes conversational authoring the product's core loop and finishes it end to end.**
The headline is simple: *a user chats with hermes-agent to generate and iterate the product
spec and technical design, and the same conversation carries that work all the way to an
approved, PR-tracked artifact* — without leaving the product.

Today the loop is half-built. The agent can write a document (v1), but: the user cannot see a
rendered preview of what is being produced or make a quick manual tweak; agent writes commit
invisibly to the branch with no pull request to review or track; and the approval decision —
the thing the whole conversation builds toward — happens out of band in a separate mechanic.
v3 closes those gaps so the chat-driven generation loop is complete.

## Storage model — documents on GitHub, live state in its owning store

This feature is being built while `workflow-db` / `workflow-db-mcp` move **live task and
feature state** out of git and into Postgres for the features the Go orchestrator owns.
v3 must respect that split, which runs along **two independent axes**:

- **Narrative documents stay on GitHub, always.** `product-spec.md`, `technical-design.md`,
  and handoff documents remain in the management repo regardless of orchestrator
  (`workflow-db` keeps git for narrative artifacts — only live task state moves to the DB).
  v3's document-authoring, commit, and PR pipeline therefore **always targets GitHub** and is
  identical for legacy (`ts`) and database (`go`) features. This is the agent's job: edit the
  document and commit it to GitHub via a tracked PR.
- **Lifecycle / review state lives in whichever store owns the feature.** For a legacy `ts`
  feature, stage `review_status` lives in `status.yaml` in git. For a `go` feature it lives in
  the Postgres database (no `status.yaml`). The in-chat Approve / Reject action therefore must
  drive the transition in the **owning store** — git for `ts`, the DB write path for `go` —
  not assume a `status.yaml` file always exists.

Net: **document content is a GitHub concern (one path for all features); approval state is a
store-of-record concern (git or DB, by owner).** v3 keeps these cleanly separated.

## Problem

### The generation loop has no in-product feedback or finishing surface
A user asks the agent to draft a spec and the agent writes it — but the user experiences this
as a black box. There is no rendered **preview** of the document as it is generated, no way to
make a small **manual correction** without asking the agent to regenerate a whole section, and
no in-product view of the result other than re-reading raw Markdown.

### Agent writes are invisible and untracked
When the agent writes a document, it commits directly to the feature branch. There is no pull
request to open, review, comment on, or track; no diff surfaced before the change lands; and
no status the UI can show ("draft committed", "PR open", "merged"). The human is asked to
accept generated content with no reviewable change object in front of them.

### Approval lives outside the conversation
Approving the generated product spec or technical design is the decision the whole loop builds
toward, yet it happens nowhere near the chat. The user finishes iterating with the agent, then
leaves the product to run `approve-feature` separately. The single most important human
action in the lifecycle has no presence where the work happened.

## Goals

- **G1 — Conversational authoring is the primary path.** A user chats with hermes-agent to
  generate and iteratively refine `product-spec.md` and `technical-design.md`. The agent
  produces and updates the documents through tool-calls in response to the conversation;
  chat is the main authoring surface.
- **G2 — Live preview of the generated document.** As the agent generates and updates a document,
  the center panel shows a rendered Markdown **preview** — headings, lists, tables, links —
  so the user sees the formatted artifact taking shape, not raw text.
- **G3 — Light manual edits.** The user can make small inline corrections to the generated
  document in-product (fix a sentence, add a bullet) without round-tripping through the agent.
  Manual edits and agent edits converge on **one document and one change stream** — not two
  parallel write paths. (Full IDE-style editing is explicitly not the goal — see NG.)
- **G4 — PR-tracked commits on GitHub, continuously.** Every change to a document —
  agent-generated or manually edited — is committed to the feature's management-repo branch on
  GitHub and reflected in a **single tracked pull request per feature** that carries both the
  product spec and the technical design, created if absent and updated on every save, so the
  current diff is always reviewable on GitHub while drafting. This path is the same for `ts`
  and `go` features (narrative documents always live in git).
- **G5 — Read-before-write safety.** Before applying an edit, the agent must **check the
  latest committed state** of the document (current branch head / file content) and base its
  change on that, so a generation does not silently clobber a manual edit (or another agent
  turn) made since it last read the file. A stale-base edit is detected and surfaced, not
  blindly overwritten.
- **G6 — PR status visible in-UI.** The feature view shows the document PR's state — branch, URL,
  open/merged — with a link to GitHub, so the user always knows whether their work is
  committed, in review, or merged.
- **G7 — In-chat approval / rejection, store-aware.** Approving or rejecting the product spec
  or technical design is surfaced as an action inside the chat, rendered from an agent
  tool-call (an interactive approve/reject card with a comment field). Acting on it drives the
  existing lifecycle transition **in the feature's owning store** — `approve-feature` /
  `reject-feature` against `status.yaml` for a `ts` feature, or the equivalent DB write for a
  `go` feature.
- **G8 — Approval is a review decision, not a merge.** The in-chat Approve action sets the
  stage `review_status` to `approved` and advances the lifecycle. It does **not** merge the
  document PR — merging stays a separate, surfaced step. No lifecycle gate is bypassed; only a
  human approves a stage.
- **G9 — Reversible state via the agent.** The user can tell the agent to **roll back** a
  lifecycle state change — e.g. re-open an approved stage to keep editing — and the agent
  performs the reverse transition (with revalidation) in the owning store, rather than the
  state being a one-way door.
- **G10 — Stack-aware technical design.** When authoring the **technical design**, the agent
  loads the relevant `technical_skills` (e.g. `postgres-best-practices`,
  `typescript-best-practices`, `go-best-practices`, `nestjs-best-practices`,
  `nextjs-best-practices`, `backend-engineer`, `frontend-engineer`) as normative context, so
  the generated design reflects this platform's actual stack conventions instead of generic
  advice. Skills are selected by the repos/stack the feature touches — **not** all skills
  loaded indiscriminately. This applies the existing per-task required-skills mechanism at the
  tech-design authoring stage. (Product-spec authoring does not need this.)

## Non-goals

- **NG1 — No tasks.md / task-YAML authoring in v3.** The conversational authoring loop covers
  `product-spec.md` and `technical-design.md` only. Task breakdown stays owned by `tech-lead`.
  (Handoff documents also stay on GitHub but are not authored by this loop in v3.)
- **NG2 — Not a full IDE / code editor.** v3 provides *light* manual Markdown edits on the two
  artifacts, not a peer-grade text editor and not editing of files in implementation repos.
  The primary authoring path is the agent; manual editing is a correction affordance.
- **NG3 — No real-time collaborative editing.** No multi-cursor, no CRDT/OT co-editing, no
  presence. One writer (agent or human) holds the document at a time; concurrency is handled
  by the read-before-write check (G5) and conflict *detection*, not live merge.
- **NG4 — No WYSIWYG.** Markdown text stays the source of truth; the preview renders it.
- **NG5 — No new approval semantics.** v3 moves approval into the chat and ties it to a
  reviewable PR, but the `review_status` values, transitions, and the human-only approval rule
  are unchanged. Agents prepare and surface; they do not approve stages.
- **NG6 — Approve does not auto-merge.** Approval sets review status only (G8); the document PR
  merge is separate.
- **NG7 — No direct-to-main writes.** Document changes land on the feature branch and reach `main`
  only via the tracked PR being merged — consistent with the management-repo
  "no direct push to main" rule.
- **NG8 — Does not move narrative documents into the DB.** v3 keeps `product-spec.md` /
  `technical-design.md` / handoffs in git, exactly as `workflow-db` intends. It only makes the
  approval-state write target the owning store.
- **NG9 — No change to v2's three-panel layout, session history, or context tools.** v3 adds
  preview + light editing to the center panel, the commit/PR pipeline, the approval affordance,
  and store-aware approval; the rest of v2 ships as-is.

## User Flows

### Generating a spec by chatting
1. The user opens a new feature; the center panel shows the empty/template `Product Spec`.
2. The user types: *"Draft the product spec for a feature that adds CSV export to the
   dashboard. Keep it to three goals."*
3. The agent asks any clarifying questions, then generates the document via its document tool-call —
   after reading the current file state (G5). The tool-call renders in chat as a card; the
   center panel's **preview** updates to show the rendered spec taking shape.
4. The user iterates: *"Add a non-goal about scheduled exports, and tighten Goal 2."* The
   agent re-reads the latest document, updates it, and the preview and the tracked PR update.

### Making a light manual correction
1. While reviewing the preview, the user spots a typo or wants to add one bullet.
2. The user makes the small edit inline and saves. The change commits to the feature branch
   and updates the same tracked PR — the identical write path the agent uses. The next agent
   turn reads this edit before generating (G5), so the manual change is not clobbered.

### Seeing where my work is
At all times the feature view shows the document PR's state for the feature: no PR yet / PR open
(link to GitHub) / merged. As the agent generates and as the user edits, the diff on that PR
stays current.

### Approving from the chat
1. When the document is ready, the chat renders an **approval affordance** from an agent tool-call:
   a card naming the stage (e.g. "Approve Product Spec?") with **Approve** / **Reject**
   controls and a review-comment field.
2. The user clicks **Approve** → the lifecycle transition runs in the feature's owning store:
   `status.yaml` (ts) or the DB (go). `review_status` → `approved`, the feature advances,
   history is written. The document PR is **not** merged by this action; its status remains visible
   for the human to merge separately.
3. Clicking **Reject** → the reverse: `review_status` → `rejected` with the comment; the agent
   iterates and re-prepares from the same conversation.
4. The left-panel stage badge and the PR indicator update to reflect the new state.

### Rolling back an approval
1. After approving, the user decides more changes are needed: *"Actually, re-open the product
   spec — I want to revise the goals."*
2. The agent performs the reverse lifecycle transition in the owning store (re-open /
   revalidation), and the user resumes editing/generating. The document and its PR are untouched by
   the rollback; only the review state moves back. (G9)

## Scope

### In scope

**Conversational authoring + agent tools (hermes-agent workflow_plugin)**
- A document-generation/edit tool the agent calls to create or update `product-spec.md` /
  `technical-design.md`, which **reads the latest committed file first** (G5) and routes the
  write through the shared commit+PR pipeline below (one write path with manual edits — G3).
- An **approval tool** the agent calls to surface the approve/reject affordance in chat for a
  given stage. The card is interactive; the human's choice triggers the lifecycle transition
  in the owning store (G7). The agent surfaces the control; it does not approve (NG5).
- A **state-rollback tool** the agent calls to reverse a lifecycle transition (re-open an
  approved stage) in the owning store, on the user's instruction (G9).
- **Technical-skill loading for tech-design authoring** (G10): resolve the feature's stack
  from the repos it touches and load the matching `technical_skills` `SKILL.md` content into
  the agent's context before it generates/iterates the technical design.
- Slash-command picker (v1/v2) extended to expose the new document, approval, and rollback tools.

**Preview + light editing (digital-factory-ui — center panel)**
- A rendered Markdown **preview** of the current document, reusing the existing read-view
  Markdown renderer, that updates as the agent generates/edits.
- A **light inline edit** affordance for the `Product Spec` / `Technical Design` tabs:
  edit the Markdown, **Save** / **Discard**, dirty-state tracking, unsaved-changes guard.
  Scoped to small corrections, not a full editor (NG2).
- A **PR status indicator** showing the document PR's branch, state (none / open / merged), and a
  link to open it on GitHub.

**Document-edit + PR pipeline (backend)**
- A backend capability to **write a document, commit it to the feature's management-repo
  branch on GitHub, and create-or-update one tracked pull request per feature** (carrying both
  artifacts) — used by both the agent tool-call and the human Save action so there is a single
  write path (G3, G4). Identical for `ts` and `go` features.
- Commits respect the feature-branch and "no direct push to main" rules; PR creation goes
  through the existing PR mechanism (`pr-create` / the GitHub adapter / `GITHUB_TOKEN`), not
  ad-hoc `gh` calls.
- The pipeline supports the read-before-write check (G5): expose the latest committed content
  / branch head so the agent can base an edit on current state and detect a stale base.
- An endpoint to **read the current document PR status** for a feature (branch, URL, open/merged)
  so the UI indicator (G6) can render it.

**Store-aware lifecycle integration**
- Approve / Reject / Rollback resolve the feature's **owner** and write the `review_status`
  transition (`draft` → `awaiting_approval` → `approved` / `rejected`, and the re-open reverse)
  to the correct store: `status.yaml` + history for `ts` features (as `approve-feature` /
  `reject-feature` do today), or the DB write path for `go` features. Approve sets status only;
  it does not merge the PR (G8).

### Out of scope (tracked separately)
- Task breakdown authoring / editing via chat (follow-on; stays with `tech-lead`).
- Handoff-document authoring via the chat loop (handoffs stay on GitHub but are not in this loop).
- Full IDE-grade editing, live collaborative co-editing, presence, WYSIWYG.
- Editing artifacts in implementation repos.
- Auto-merge of the document PR on approval (merge stays a surfaced, human-driven step).

## Skills and agent tools

The in-chat affordances are **thin wrappers that expose existing workflow skills as agent
tool-calls** — v3 does not reinvent the lifecycle mechanics, it surfaces them in the chat and
makes them store-aware. The workflow skills live in agent-workflow `claude/workflow_skills/`.

**Existing workflow skills v3 builds on:**
- `approve-feature` — backs the in-chat **Approve** action (G7). Updates the stage review
  state, records actor + timestamp, appends review history, advances the feature.
- `reject-feature` — backs the in-chat **Reject** action (G7). Records actor, timestamp,
  comment, appends history, updates `next_action`.
- `set-feature-stage` — backs the **rollback / re-open** action (G9). Moves the feature back
  to a prior stage, **preserves artifacts**, **sets revalidation flags**, and never deletes
  work — exactly the reversible-state mechanic. Allowed targets include `product_spec` and
  `technical_design`.
- `pr-create` — backs the **commit + PR pipeline** (G4): opens the tracked PR via the GitHub
  REST API using `GITHUB_TOKEN`, not ad-hoc `gh` calls.
- `resolve-project-env` — resolves env values (`GITHUB_TOKEN`, `GIT_AUTHOR_*`, etc.) before
  any git / PR operation.
- `init-feature`, `tech-lead` — existing document-generation context the authoring loop operates
  within (templates, tech-design production).

**New skills / tools v3 adds:**
- A **document-generation/edit tool** (hermes-agent) that reads the latest committed file first
  (G5), writes `product-spec.md` / `technical-design.md`, and routes the write through
  `pr-create`.
- **Store-aware variants** of `approve-feature` / `reject-feature` / `set-feature-stage`:
  today these skills write `status.yaml` in git; for a `go` feature the same transition must
  write the Postgres store (`workflow-db`). v3 adds a DB-aware path (or a backend abstraction)
  so the tools work for both `ts` and `go` features (ties to OQ2).
- The **UI rendering** of these tool-calls as interactive cards (approve / reject / rollback)
  and the **PR status indicator** in the feature view.

## Open Questions (to resolve in technical design)

- **OQ1 — Stale-base resolution UX.** G5 mandates read-before-write and stale-base detection.
  When a conflict is detected (the file changed since the agent/user last read it), what is the
  surfaced behavior — reload-and-retry, present a diff for the user to choose, or warn and let
  the user decide? v3 does detection, not automatic merge (NG3).
- **OQ2 — `go`-feature approval write path.** For a `go` feature, the approval transition must
  write to the DB. Does v3 call the `workflow-db` / `workflow-db-mcp` write path directly, or
  go through a backend endpoint that abstracts the store? (Depends on what `workflow-db-mcp`
  exposes.) For a `ts` feature this is the existing `approve-feature` git path.
- **OQ3 — Rollback transition definition.** Which exact reverse transition(s) implement "re-open
  an approved stage," and how do they interact with the existing `revalidation` fields in
  `status.yaml` (ts) and their DB equivalents (go)?
- **OQ4 — Technical-skill selection (G10).** How is the relevant `technical_skills` set chosen
  for a feature — inferred from the touched repos' stack in `workspace.yaml`, declared
  explicitly, or agent-selected with a confirmation? And what is the upper bound on how many
  are loaded so context stays focused?

## Success Criteria

- A user can generate a complete product spec or technical design purely by chatting with the
  agent, watching the rendered preview update as it is produced, without leaving the product.
- A user can make a small manual correction to the generated document and save it through the same
  path the agent uses, and a subsequent agent turn does not clobber it (read-before-write).
- Every agent generation and every manual save commits to the feature's management-repo branch
  on GitHub and is reflected in one tracked PR per feature (carrying both documents) — created if
  none exists, updated if one does — and never via a direct push to `main`. This holds for both
  `ts` and `go` features.
- The feature view shows the document PR's state (none / open / merged) with a working GitHub link,
  updating within one refresh of any change.
- From the chat, a human can Approve or Reject the product spec / technical design via an
  affordance rendered from an agent tool-call; the action drives the lifecycle transition in
  the feature's owning store (git for `ts`, DB for `go`), writes the correct review + history
  record, and does **not** merge the PR.
- A user can instruct the agent to roll back an approval (re-open a stage) and resume editing,
  with the review state moving back in the owning store and the document/PR untouched.
- Lint, type-check, and the full test suites of the touched repos pass before any PR.

## Reference
- v1 spec: `docs/features/m3-agent-chat/product-spec.md`
- v2 spec: `docs/features/m3-agent-chat-v2/product-spec.md` (three-panel layout, session
  history, context tools — the surface v3 extends)
- Storage split: `docs/features/workflow-db/product-spec.md` and
  `docs/features/workflow-db-mcp/` — live task/feature state moves to Postgres for `go`
  features; narrative documents (`product-spec.md`, `technical-design.md`, handoffs) stay in git.
- Approval mechanics: `approve-feature` and `reject-feature` skills; stage `review_status`
  values and transitions in `CLAUDE.md`; `revalidation` fields in `status.yaml`.
- PR creation: `pr-create` skill and the `workspace-github-adapter` repo; `GITHUB_TOKEN` in
  project `.env`. Management-repo "no direct push to main" and feature-branch rules in
  `CLAUDE.md`.
- Touched repos (subject to technical design): `hermes-agent` (document / approval / rollback
  tools), `digital-factory-ui` (preview + light editing + PR indicator), `workflow-backend`
  and/or `workspace-github-adapter` (commit + PR pipeline, status endpoint), and the
  `workflow-db` write path for `go`-feature approval state.
