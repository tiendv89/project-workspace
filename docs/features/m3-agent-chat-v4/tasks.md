# Tasks — m3-agent-chat-v4 (The Thread: Team Chat, Channels, @mention, Triggered Agent)

> Feature status (reference): `in_tdd` → task planning. Stage `tasks`: awaiting approval.
> **Machine-mutable state (status, depends_on, branch, pr, log) lives in `tasks/T<n>.yaml`** —
> this file is narrative only. Source of truth for state is the YAML.

Design basis: `technical-design.md` (§4 chosen design, §6 parallelization). 10 tasks across 3
repos: **hermes-agent** (×5 — conversation backend + transport + channels + workspace threads),
**digital-factory-ui** (×4 — UI), **user-service** (×1 — member/role reads). `workflow-bff` and
`workflow-backend` need no change.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | hermes-agent: conversation data model + store (members, authorship, mentions, channels) | — |
| T5 | 1 | user-service: list workspace members + caller workspace-role endpoints | — |
| T2 | 2 | hermes-agent: @mention parse/resolve + @agent-gated dispatch + decoupled send service | T1 |
| T4 | 2 | hermes-agent: channels API (member create, admin delete, list, join) | T1, T5 |
| T3 | 3 | hermes-agent: real-time SSE fan-out (pub/sub, stream, send, typing, agent republish) | T2 |
| T6 | 4 | digital-factory-ui: persistent subscription transport + per-message attribution | T3 |
| T7 | 4 | digital-factory-ui: @mention typeahead composer + mention tokens + unread indicator | T2, T5, T6 |
| T8 | 4 | digital-factory-ui: Channels nav + list + create (any member) / admin-only delete + member UI | T4, T5, T6 |
| T9 | 2 | hermes-agent: workspace-level team threads (kind='thread', feature_id='' create + member-scoped listing) | T1 |
| T10 | 4 | digital-factory-ui: workspace Team Chat nav entry + workspace-thread list + create | T6, T9 |

---

## T1 — hermes-agent: conversation data model + store

### Description
Foundation for the whole feature (design §4.1). Add an additive Postgres migration + SQLAlchemy
models and store functions to hermes-agent so a conversation gains members, per-message
authorship, mentions, and a channel concept. No existing columns change.

- New tables: `session_members(session_id, user_id, role_label?, added_by, added_at)` PK
  `(session_id, user_id)`; `message_mentions(id, message_id, session_id, mentioned_id,
  mentioned_kind ∈ {user, agent}, read_at?)`.
- New columns (nullable / defaulted, back-compat): `messages.author_id` (sender `X-User-Id`, or
  `agent` sentinel for assistant messages); **`sessions.kind`** (`'thread' | 'channel'`, default
  `'thread'`) — the channel discriminator. **No separate `channels` table** — a channel is a
  `sessions` row with `kind='channel'`, `feature_id=''`, `title`=name, `user_id`=creator;
  description in `metadata` (or a small nullable column). Name uniqueness via partial unique index
  `UNIQUE(workspace_id, lower(title)) WHERE kind='channel' AND NOT archived`.
- Store functions: add/remove/list members; member-scoped session listing (own ∪ member-of, G7);
  create channel (a `kind='channel'` session) / hard-delete (messages cascade via the
  `messages.session_id` FK); persist + resolve mentions; unread-mention count per user.

### Required skills
- python-best-practices
- postgres-best-practices
- backend-engineer

### Subtasks
- [ ] Write the additive migration (`session_members`, `message_mentions`, `messages.author_id`,
      `sessions.kind` + partial unique index); verify it applies on a copy of the current schema
      without touching existing columns.
- [ ] Add/extend SQLAlchemy models in `src/db/models.py` for the new tables + columns.
- [ ] Implement member store fns (add/remove/list; member-scoped session listing own ∪ member-of).
- [ ] Implement mention store fns (persist, resolve against members + `@agent`, unread count).
- [ ] Implement channel store fns (create `kind='channel'` session, list, hard-delete).
- [ ] Unit tests: member listing scope, mention persistence, `kind='channel'` session creation,
      unique channel name, hard-delete cascades the channel's messages.
- [ ] Run full Python suite + lint before PR.

---

## T5 — user-service: list workspace members + caller workspace-role endpoints

### Description
Provide the identity reads the team-chat surface needs (design §4.5, §3.6). **Verify what already
exists; implement only the gaps.** Two reads, behind the existing `/bff/user-service` identity
surface:
- **List workspace members** → `(user_id, display_name, avatar_url, role)` — powers the `@mention`
  typeahead (T7), the member-add picker (T8), and read-time attribution resolution (T6).
- **Caller's workspace role** (or a membership-with-role lookup) — powers the channel-admin gate
  (T4). Define precisely what "workspace admin" means here (resolves design OQ2).

### Required skills
- go-best-practices
- backend-engineer
- postgres-best-practices

### Subtasks
- [ ] Audit existing user-service endpoints for member-list and role lookups; document gaps.
- [ ] Implement/confirm a list-workspace-members endpoint with the field shape above.
- [ ] Implement/confirm a caller-workspace-role (or membership+role) endpoint; define "admin".
- [ ] Enforce auth (service token / BFF identity) on both reads.
- [ ] Tests for both endpoints; run full Go suite + `golangci-lint` (zero errors) before PR.

---

## T2 — hermes-agent: @mention parse/resolve + @agent-gated dispatch + decoupled send service

### Description
Implements the trigger guardrail (design §4.2, §3.5; product G2/G3, NG12). Decouple "post a
message" from "run an agent turn".
- A **send service** that persists the human message (`author_id = X-User-Id`), parses `@…` tokens,
  resolves them against thread members (by **unique handle**) + the `@agent` sentinel, persists
  `message_mentions`, and then **gates** the agent turn.
- **Trigger rules (resolved):** only an **explicit `@agent`** triggers a turn; a plain reply to the
  agent does **not** re-trigger. **Bare-message default keyed on `feature_id`:** a bare message
  (no `@agent`) triggers the agent in a **feature thread** (`feature_id` set) but **never** in a
  **feature-less session** (`feature_id=''` — a channel or a workspace-level thread, T9).
- Reuse the per-session `_active_runs` guard; multiple `@agent` mentions during an in-flight turn
  **coalesce into one** follow-up turn (not N turns).
- **Container-aware agent context (keyed on `feature_id`, not `kind`):** a session with a
  `feature_id` (feature thread) keeps full v3 behaviour; a feature-less session (`feature_id=''` —
  channel or workspace thread) gets workspace-scoped context and the feature authoring/approval
  tools are inert (NG12 — enforced by the absent `feature_id`, no new guard).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Implement mention parsing + resolution (members + `@agent`); persist `message_mentions`.
- [ ] Implement the send service: persist human message with `author_id`, no implicit agent call.
- [ ] Add the dispatch gate: explicit `@agent` triggers; reply does not re-trigger; bare message
      triggers in a feature thread but not in a channel; coalesce rapid `@agent` mentions.
- [ ] Wire container-aware context (feature vs channel) into the dispatch.
- [ ] Tests: explicit `@agent` ⇒ one turn; channel bare message ⇒ no `run_conversation`; feature
      bare message ⇒ one turn; rapid `@agent` mentions ⇒ one coalesced turn; channel omits feature
      tools; unknown handles handled.
- [ ] Run full Python suite + lint before PR.

---

## T3 — hermes-agent: real-time SSE fan-out

### Description
Real-time multi-viewer delivery over SSE (design §4.3, §3.1, §3.3; product G4). No BFF change
(SSE only — the BFF rejects WebSocket).
- New in-process pub/sub (`src/realtime/bus.py`): per-thread topic; `subscribe()` returns an
  `asyncio.Queue`; `publish(thread_id, event)` fans out. Valid because hermes is single-instance
  per workspace; swap to Postgres `LISTEN/NOTIFY` only on horizontal scale (OQ1).
- `GET /api/v1/threads/{id}/stream` (SSE, `require_identity`, member-only): relays
  `message.created`, agent token deltas + `hermes.tool.progress` + `hermes.artifact.saved`,
  `member.changed`, ephemeral `typing`/`agent.working`; `?since=<cursor>` replays missed persisted
  messages on (re)connect.
- `POST /api/v1/threads/{id}/messages` (the T2 send service) returns `202`, not a stream.
- `POST /api/v1/threads/{id}/typing` — ephemeral, published not persisted.
- Republish the agent turn's output to the **thread topic** so all subscribers see it (not just
  the caller). Refactor legacy `POST /chat` through this path (or a thin shim during migration —
  OQ4).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Implement the in-process pub/sub bus with per-thread topics + subscriber queues.
- [ ] Implement `GET …/threads/{id}/stream` (SSE) with member-only guard + `?since=` replay.
- [ ] Implement `POST …/threads/{id}/messages` (202) and `…/typing` (ephemeral).
- [ ] Republish agent-turn frames to the thread topic; verify all subscribers receive them.
- [ ] Refactor/relay legacy `/chat` through the new path (or shim).
- [ ] Tests: cross-subscriber delivery, agent-output fan-out, replay on reconnect, non-member
      rejection, typing not persisted.
- [ ] Run full Python suite + lint before PR.

---

## T4 — hermes-agent: channels API (member create, admin delete, list, join)

### Description
Public channels with **open creation** and **admin-gated deletion** (design §4.4; product
G10/G11, NG10). A channel is a `kind='channel'` session (T1) — it reuses the thread conversation
machinery (T2/T3 messaging); no channel-specific messaging.
- `GET /api/v1/channels?workspace_id=` → list `kind='channel'`, non-archived sessions (any member).
- `POST /api/v1/channels {workspace_id, name, description?}` → **open to any workspace member** (no
  role check); create a `kind='channel'`, `feature_id=''` session with `title`=name; creator
  auto-joined.
- `DELETE /api/v1/channels/{id}` → **admin-gated** (verify caller is a workspace admin via
  user-service, T5); **hard-delete** the channel session (messages cascade via FK); publish
  `channel.deleted` so live viewers update.
- `POST /api/v1/channels/{id}/join` → any workspace member joins.

### Required skills
- python-best-practices
- postgres-best-practices
- backend-engineer

### Subtasks
- [ ] Implement channel list/create/delete/join routes under `/api/v1`.
- [ ] Creation: open to any member (no role check); create `kind='channel'` session + auto-join creator.
- [ ] Delete gate: call user-service for the caller's workspace role; 403 if not admin.
- [ ] Hard-delete on delete (messages cascade); publish `channel.deleted` to the thread topic (T3 bus).
- [ ] Tests: any member create ⇒ channel + joined; **non-admin delete ⇒ 403**; admin delete ⇒
      channel + messages removed + `channel.deleted` event; join adds membership; unique name enforced.
- [ ] Run full Python suite + lint before PR.

---

## T6 — digital-factory-ui: persistent subscription transport + per-message attribution

### Description
Rebuild the FE chat transport around a persistent subscription and add per-message attribution
(design §4.6; product G4/G5).
- Replace per-turn `streamChatTurn` with a persistent `GET …/threads/{id}/stream` subscription
  (via `@microsoft/fetch-event-source`) opened on thread open; send via
  `POST …/threads/{id}/messages`; reconnect with `?since=` replay.
- Extend `HermesMessage` (`types.ts`) with `author {id, name, avatarUrl, roleLabel}` and render
  attribution in `message.tsx` (human name/avatar; agent clearly marked). Agent output arrives on
  the same stream attributed to `@agent`.
- v3's `ApprovalCard` / `DocumentEditCard` continue to render in feature threads.

### Required skills
- nextjs-best-practices
- typescript-best-practices
- frontend-engineer

### Subtasks
- [ ] Add stream-subscribe + message-send service fns in `src/services/hermes-agent/`.
- [ ] Swap `agent-chat-panel.tsx` from per-turn streaming to subscribe + send; handle reconnect.
- [ ] Extend `HermesMessage`/`types.ts` with `author`; render attribution in `message.tsx`.
- [ ] Verify agent deltas/tool-progress render live; v3 approval/document cards still work in
      feature threads.
- [ ] Tests/typecheck/lint; run the full JS/TS suite before PR.

---

## T7 — digital-factory-ui: @mention typeahead composer + mention tokens + unread indicator

### Description
The `@mention` UX and in-app indicators (design §4.7; product G2/G6). In-app only — no Slack/email.
- Add an `@` **typeahead** to `prompt-input.tsx` (alongside the existing `/` slash picker) listing
  thread members + `@agent` (members from T5); insert a resolvable mention token.
- Render mention tokens distinctly in `message.tsx`.
- In-app **mention/unread indicator** driven by `message_mentions.read_at` (T2): a per-thread/
  channel badge **plus a workspace-level aggregate count** in the nav. **Opening a thread/channel
  clears all its unread mentions** (resolved).

### Required skills
- nextjs-best-practices
- typescript-best-practices
- heroui-react
- frontend-engineer

### Subtasks
- [ ] Build the `@` typeahead (members + `@agent`) in the composer; coexist with the slash picker.
- [ ] Render mention tokens in the transcript.
- [ ] Wire the unread/mention indicator: per-thread/channel badge + nav workspace-aggregate count;
      opening a thread/channel clears all its unread mentions.
- [ ] Confirm no external-notification path exists (in-app only).
- [ ] Tests/typecheck/lint; run the full JS/TS suite before PR.

---

## T8 — digital-factory-ui: Channels nav + list + create/admin-delete + member UI

### Description
The Channels surface and membership management UI (design §4.8; product G9/G10/G11, NG10).
- Add a **Channels** entry to `nav-rail.tsx` + a workspace-scoped channel list (from T4); opening a
  channel renders the same chat surface (T6/T7) bound to the channel's thread.
- **Create** channel control available to any member; **delete** control **admin-only**
  (hidden/disabled for non-admins per the role from T5).
- **Member list UI** (view/add/remove) for both feature threads and channels (members from
  T1/T5), with role-label display (G9).

### Required skills
- nextjs-best-practices
- typescript-best-practices
- heroui-react
- frontend-engineer

### Subtasks
- [ ] Add the Channels nav entry + channel list view (workspace-scoped).
- [ ] Render a channel's conversation using the shared chat surface (T6/T7).
- [ ] Add a create-channel control for any member; gate the delete control to admins (role from T5).
- [ ] Add member list UI (view/add/remove) with role labels for threads + channels.
- [ ] Tests/typecheck/lint; run the full JS/TS suite before PR.

---

## T9 — hermes-agent: workspace-level team threads

### Description
Closes the workspace-chat gap (design §4.9; product G12). Today a `kind='thread'` session always
carries a `feature_id`, so the membership-scoped collaboration surface exists **only** inside a
feature; the only workspace-level conversation is a named public channel. Add a workspace-level
**team thread**: a `kind='thread'`, `feature_id=''` session with explicit membership (unlike a
public channel), reusing the full team-chat stack. **No schema change beyond T1** — the `kind`
discriminator and member/mention/stream model already cover it.

- `POST /api/v1/threads {workspace_id, title?, members?}` → create a `kind='thread'`,
  `feature_id=''` session; creator auto-joined; optional initial members added.
- Extend the member-scoped session listing (T1, G7) so a member's history returns their feature
  threads **and** workspace-level threads (own ∪ member-of), filterable to the workspace-thread
  set for the Team Chat surface; non-members are excluded.
- Conversation, mentions, `@agent`-gated dispatch, and SSE fan-out (T2/T3) apply **unchanged** —
  they key on session id / `feature_id`, so a workspace thread automatically gets workspace-scoped
  agent context and explicit-`@agent`-only triggering (NG12). **No T2/T3 code change.**

### Required skills
- python-best-practices
- postgres-best-practices
- backend-engineer

### Subtasks
- [ ] Implement `POST /api/v1/threads` (create `kind='thread'`, `feature_id=''` session; creator
      auto-joined; optional initial members).
- [ ] Extend the member-scoped session listing to include workspace threads; add a
      workspace-thread filter for the Team Chat surface.
- [ ] Verify dispatch/context (T2) treats the new feature-less thread as workspace-scoped and
      explicit-`@agent`-only — no feature authoring/approval tools — without new code.
- [ ] Tests: create ⇒ `kind='thread'`, `feature_id=''`, creator joined; listing returns own ∪
      member-of and excludes non-members; workspace thread omits feature tools; bare message does
      not trigger the agent (feature-less), explicit `@agent` does.
- [ ] Run full Python suite + lint before PR.

---

## T10 — digital-factory-ui: workspace Team Chat nav entry + workspace-thread list + create

### Description
The workspace-level team-chat surface (design §4.9; product G12). Reuses the shared chat surface
(T6), `@mention` composer (T7), and member list/add-remove UI (T8) — adds only the workspace-level
entry point and create/list wiring.

- Add a workspace-level **Team Chat** entry to `nav-rail.tsx` (alongside Channels) listing the
  caller's workspace threads (from T9).
- A **create-thread** control (available to any workspace member) that opens a new workspace
  thread and lets the creator add members.
- Opening a workspace thread renders the **same** chat surface as feature threads and channels
  (T6), with the `@mention` composer (T7) and member list/add-remove UI (T8). No feature
  authoring/approval affordances render (no `feature_id`).

### Required skills
- nextjs-best-practices
- typescript-best-practices
- heroui-react
- frontend-engineer

### Subtasks
- [ ] Add the Team Chat nav entry + workspace-thread list view (from T9).
- [ ] Add a create-thread control (any member) with initial member selection.
- [ ] Render a workspace thread using the shared chat surface (T6/T7) + member UI (T8).
- [ ] Confirm no feature authoring/approval affordances render in a workspace thread.
- [ ] Tests/typecheck/lint; run the full JS/TS suite before PR.
