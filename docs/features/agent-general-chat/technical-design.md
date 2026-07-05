
# Technical Design

## Feature
- Feature ID: `agent-general-chat`
- Title: General Chat, Direct Messages, Cross-Feature Agent Context, and a Unified Chat Hub

## Current State

The M3 agent-chat line (`m3-agent-chat` → `v4`, all shipped) built the conversation domain
entirely inside **hermes-agent**, in its own Postgres (async SQLAlchemy + asyncpg):

- **`sessions`** (`src/db/models.py:Session`, lines 29-77) — `id`, `workspace_id`, `feature_id`
  (`NOT NULL DEFAULT ''`), `kind` (added in v4 — currently `'thread'` for feature threads and
  workspace Team Chat threads, `'channel'` for public channels), `title`, `is_active`,
  `message_count`/`tool_call_count`/token+cost counters, `metadata` JSONB.
- **`session_members`** (`src/db/models.py:SessionMember`, lines 117-133) — explicit member set
  (workspace membership alone does not grant thread access); any member can add/remove members
  (v4 G1).
- **`messages`** (`src/db/models.py:Message`, lines 80-114) — `role` (OpenAI role, not human
  identity), `content`, `author_id` (added v4 T2), tool call fields.
- **`src/db/store.py`**:
  - `create_workspace_thread` (931-984) / `list_workspace_threads` (987-1036) — workspace-level
    ad-hoc threads (`kind='thread'`, `feature_id=''`), from v4 T9/T10.
  - `list_member_sessions` (639-687) — member-scoped listing (own ∪ member-of), used by both
    Channels and Team Chat list pages.
  - `append_message` (288-336) / `update_token_counts` (108-156) — every message and every agent
    turn's token/cost counters are recorded here, **regardless of session kind**. This is the hook
    G6 rides on (see §Chosen Design).
- **`src/api/routers/threads.py`** — `create_thread_endpoint` / `list_threads_endpoint`
  (`CreateThreadRequest`, 47-50) — workspace Team Chat thread CRUD.
- **`src/api/routers/messages.py`** — `get_thread_messages` (72-98); dispatch-gate logic decides
  whether `@agent`/bare-message triggers a turn (v4 §4.2): explicit `@agent` → trigger always;
  bare message → trigger only in a feature thread (`feature_id != ''`); channel bare message →
  no trigger. `agent_dispatch.py:_run_agent_turn` (272-565) is the single entry point that runs a
  turn for **any** session kind — it is where `HermesSSETranslator.on_usage` (`sse.py:223-228`)
  and `src/services/cost_client.py:check_quota` (112-159) hook in. **There is no separate cost
  path per session kind** — every agent turn (feature thread, channel, workspace thread) already
  goes through this one metering pipeline.
- **`plugins/hooks.py:inject_context`** (164-303) — pre-LLM-call hook. For a feature session
  (`feature_id != ''`) it injects `workspace_id`, `feature_id`, repo list, stage, and loads the
  full feature-scoped tool set (`workflow_get_feature_state`, `workflow_write_product_spec`,
  etc. from `plugins/db.py:get_feature_detail`, 106-135). For `feature_id == ''` (Channels,
  workspace threads) it **deliberately omits feature tools** (v4 NG12) — the agent has no way to
  look up *any* feature, including ones outside the current session.
- **digital-factory-ui**:
  - `src/components/shell/nav-rail.tsx` — `NavRailLink`/`TasksNavButton`; separate **Channels**
    (Hash icon, `/channels`) and **Team Chat** (T10) nav-rail entries exist side by side today.
  - `/channels` + `/channels/[channelId]` pages, `CreateChannelModal`, `ChannelChatPage`,
    `ThreadMembersPanel` (member add/remove/roles — reusable, from T8).
  - `feature-workbench.tsx` — feature-thread chat surface using `useSubscriptionTransport`
    (persistent SSE subscription, replacing per-turn streaming as of v4 T6).
  - `src/stores/board.ts` + `src/hooks/board/use-sidebar-tasks.ts` — existing board/task read
    layer (`queryFn` → backend `GET` sidebar tasks), currently only rendered on the full Tasks
    page, scoped by `feature_id`.
- **user-service** — `WorkspaceMember`/`WorkspaceRole` types, `listWorkspaceMembers`,
  `getCallerWorkspaceRole` (added T8) — already lists workspace members with roles; nothing
  currently starts a 1:1 conversation from this list.
- **workflow-backend** — owns `workspace_features` (Go/Postgres); `GetWorkspaceBySlug` and
  `public_feature_id`-keyed queries (`internal/database/queries.go`, `queries_test.go:
  TestBuildFeatureWhereNameFilter`, `TestGetWorkspace_TaskCountsUsePublicFeatureID`) are the
  existing pattern for resolving a human-facing feature ID (e.g. `VOY-59`) to its row — this is
  the API the new cross-feature lookup tool must call, not a new bespoke resolver.

## Constraints

- **C1** — Agents remain triggered, never self-dispatching (thesis guardrail, unchanged from
  v4): every new surface (DM, cross-feature lookup) must go through the same explicit-`@agent`
  dispatch gate already enforced in `messages.py`/`agent_dispatch.py`.
- **C2** — The cross-feature lookup tool (G1) must be strictly read-only: it must not reuse or
  expose any of the feature-scoped **write** tools (`workflow_write_product_spec`,
  `workflow_write_technical_design`, task mutation, `approve_feature`) — only read paths.
- **C3** — DMs (G2) must reuse the existing `sessions` + `session_members` schema — no new table
  — by adding a new `kind` enum value, consistent with how Channels/Threads were added in v4
  (additive migration, no schema fork).
- **C4** — Usage/credit metering (G6) must not introduce a second accounting path — it must ride
  the existing `_run_agent_turn` → `update_token_counts` → `cost_client.check_quota` pipeline
  that already fires for every session kind today.
- **C5** — The new "Chat" nav section (G3) must not break existing deep links into
  `/channels/[channelId]` during rollout — redirect, don't 404.
- **C6** — Board panel (G4) must be read-only (NG3) and must reuse `use-sidebar-tasks.ts`'s
  existing data-fetching contract rather than a new endpoint.

## Options Considered

### Option A — New `dm` session kind + generic member-scoped thread model (chosen)
- **Pros:** Reuses 100% of v4's `session_members`, dispatch gate, SSE/subscription transport,
  and cost pipeline. Only additive changes: one new `kind` value, one new lookup tool, one new
  UI shell. Minimal migration risk (v4 already proved additive `kind` migrations work — hard
  delete cascade, unique channel name, etc.).
- **Cons:** `kind='dm'` sessions need a uniqueness constraint (one DM session per unordered pair
  of members per workspace) that channels/threads didn't need — small additional migration logic.

### Option B — Separate DM microservice / new table
- **Pros:** Cleanest conceptual separation between "team chat" and "1:1 chat."
- **Cons:** Duplicates the entire member/message/SSE/cost stack that already exists and works;
  directly contradicts C3/C4; far larger blast radius for a 1:1-only feature. Rejected.

### Option C — Give the agent full feature-tool access in every session (drop NG12)
- **Pros:** Simplest implementation — remove the `feature_id != ''` gate in `inject_context`.
- **Cons:** Violates C2 and the v4-locked guardrail (NG12) that channel/thread agent context is
  intentionally narrow — a user in a public Channel could trigger writes/approvals against any
  feature they can merely *name*, with no membership check on that *other* feature. Rejected on
  security/guardrail grounds.

## Chosen Design

### 1. Data model — additive `kind='dm'` (hermes-agent)
- Add `dm` to the existing `sessions.kind` check constraint (migration, additive — same pattern
  as v4's `channel`/`thread` addition). A DM session: `feature_id=''`, exactly **two** human
  `session_members` rows + the resident agent is implicit (as in Channels/Threads — the agent is
  addressed via `@agent`, not stored as a member row).
- New unique partial index: `(workspace_id, kind, least(member_a, member_b))` is enforced at the
  **store layer** (`src/db/store.py:create_dm`, new function mirroring `create_workspace_thread`)
  by looking up an existing DM session for the same unordered pair before creating a new one —
  reuses the existing `list_member_sessions` query shape with a `kind='dm'` filter, so "start a
  DM with X" is idempotent (opens the existing DM if one exists).
- `src/api/routers/threads.py` gains `POST /dms` (`{other_member_id}`) → resolves-or-creates,
  returns the session; `GET /dms` lists the caller's DMs (thin wrapper over
  `list_member_sessions(kind='dm')`).

### 1a. Table changes and DB migration (hermes-agent)

No new tables. One additive migration, following the same pattern as the prior `kind` additions
(`channel`/`thread`) in the v4 migration set under `migrations/`.

**Table: `sessions`** — widen the existing `kind` check constraint to accept `'dm'`.

| Column | Change |
|---|---|
| `kind` | Existing `CHECK (kind IN ('session','thread','channel'))` (or equivalent enum) is replaced with `CHECK (kind IN ('session','thread','channel','dm'))`. No column type/name change. |
| `feature_id` | Unchanged — `dm` sessions use `feature_id=''`, same convention as `channel`/`thread`. |
| `title` | Unchanged — for `dm` sessions the UI derives a display title client-side from the other member's name; no title is required server-side. |

**Table: `session_members`** — no column changes. A `dm` session simply has exactly two rows
(the two human participants); this is enforced in application code (`create_dm`), not a new
DB constraint, to stay consistent with how membership cardinality for `channel`/`thread` is
also app-enforced today.

**New index** — supports the resolve-or-create lookup (`create_dm`) without a full-table scan:

```sql
CREATE INDEX IF NOT EXISTS idx_session_members_session_member
    ON session_members (session_id, member_id);
```

(Session/member pair uniqueness for a `dm` — i.e. "only one DM session per pair of humans per
workspace" — is resolved by `create_dm` querying existing `dm` sessions via this index and the
`sessions.workspace_id` column before inserting; no DB-level uniqueness constraint is added,
matching the existing app-enforced-uniqueness pattern used for channel names in v4.)

**Migration file** — new file under `migrations/`, next sequential number after the latest v4
migration (e.g. `migrations/00017_add_dm_session_kind.sql` — exact number to be confirmed against
the latest file in the directory at task time):

```sql
-- 00017_add_dm_session_kind.sql
-- Additive: widen sessions.kind to support 1:1 Direct Message sessions (agent-general-chat G2).

BEGIN;

ALTER TABLE sessions
    DROP CONSTRAINT IF EXISTS sessions_kind_check;

ALTER TABLE sessions
    ADD CONSTRAINT sessions_kind_check
    CHECK (kind IN ('session', 'thread', 'channel', 'dm'));

CREATE INDEX IF NOT EXISTS idx_session_members_session_member
    ON session_members (session_id, member_id);

COMMIT;
```

**Rollback** (down migration, if the project's migration runner supports it):

```sql
-- 00017_add_dm_session_kind_rollback.sql
BEGIN;

DROP INDEX IF EXISTS idx_session_members_session_member;

ALTER TABLE sessions
    DROP CONSTRAINT IF EXISTS sessions_kind_check;

ALTER TABLE sessions
    ADD CONSTRAINT sessions_kind_check
    CHECK (kind IN ('session', 'thread', 'channel'));

COMMIT;
```

Rollback is only safe pre-launch (before any `dm` rows exist) — once `dm` sessions are created,
the rollback `ALTER` would fail on the `CHECK` unless those rows are migrated/deleted first. This
matches the same rollback caveat v4 documented for the hard-delete channel migration.

**No changes required** to `workflow-backend` (Go/Postgres) or `user-service` tables — both are
read-only dependencies in this design (§Dependency Analysis) and own no chat data.

### 2. Dispatch gate for DMs — no new logic (hermes-agent)
DMs behave exactly like workspace Team Chat threads in the v4 dispatch gate (`messages.py`):
`feature_id=''` ⇒ bare message does **not** trigger the agent; only explicit `@agent` does (C1).
No new branch is added to `_should_trigger_agent`-equivalent logic — a DM is simply another
`feature_id=''` session, so the existing `kind != 'channel'` bare-trigger exception used for
workspace threads (v4 T2, "feature bare message ⇒ trigger" is feature-only) is reviewed: **DMs
follow the Channel rule (no bare trigger), not the Team-Chat-thread rule**, because a DM's second
human participant should not have every message intercepted by the agent. This is the one new
conditional in the gate: `kind == 'dm'` behaves like `kind == 'channel'` for bare-message
purposes, while still allowing explicit `@agent`.

### 3. Cross-feature read-only lookup tool — `workflow_lookup_feature` (hermes-agent)
- New tool registered in `plugins/tools/` (read-only family, alongside existing `plugins/db.py`
  read helpers), exposed to the agent **only** when `session.feature_id == ''` (Channels, Team
  Chat threads, DMs) — the inverse of today's `inject_context` gate. It is **never** added to the
  tool set of a feature-scoped session (which already has the richer `get_feature_detail` path;
  no duplication there).
- Input: a feature ID/slug string extracted from the triggering message (e.g. `VOY-59`,
  `agent-general-chat`). Implementation calls **workflow-backend**'s existing feature-resolution
  path (`GetWorkspaceBySlug` + the `public_feature_id`-keyed feature query already proven by
  `TestGetWorkspace_TaskCountsUsePublicFeatureID` / `TestBuildFeatureWhereNameFilter`) via the
  same HTTP path `plugins/db.py:get_feature_detail` uses internally, scoped to the **caller's own
  workspace_id** (no cross-workspace leakage, NG5).
- Output: title, lifecycle stage/status, and a short synopsis (first paragraph of
  `product-spec.md`, fetched read-only via the same GitHub Contents API read path
  `workflow-backend`'s `DocumentHandler.GetDocumentContent` already exposes — no new fetch path).
- **Explicitly excludes** (C2): `workflow_write_product_spec`, `workflow_write_technical_design`,
  task read/write, `approve_feature`. This tool is add-only to the *read* family; it does not
  touch `plugins/tools/tasks_write.py` or any approval tool.
- `inject_context` (`plugins/hooks.py`) gains one branch: `if session.feature_id == '': tools +=
  [workflow_lookup_feature]` — symmetric to, and replacing the current NG12 blank spot, the
  existing `if session.feature_id: tools += [...feature tools]` branch.

### 4. Usage/credit metering parity (G6) — no new code path
`_run_agent_turn` (`agent_dispatch.py:272-565`) is kind-agnostic today: it calls
`update_token_counts`/`append_message`/`cost_client.check_quota` identically whether the
triggering session is a feature thread, Channel, or workspace Thread. Because DMs and the new
lookup-tool turns are dispatched through this exact same function (§2, §3 add no parallel
invocation path), **G6 is satisfied by construction** — no new metering logic is required. This
design explicitly calls out: do **not** add a bypass, discount, or separate quota check for
`kind='dm'` or for `workflow_lookup_feature` calls; they must hit `check_quota` exactly like
every other agent turn.

### 5. Unified "Chat" hub (digital-factory-ui) — new nav section, retiring the old two
- New nav-rail entry: `ChatNavButton` in `nav-rail.tsx` (new icon — `MessageSquare`, distinct
  from the existing Hash icon used by Channels today), routing to a new `/chat` route group.
- New `/chat` layout: a persistent left sidebar (Slack-style) with three collapsible sections —
  **Channels**, **Direct Messages**, **Threads** — each backed by the existing list calls
  (`listChannels`, the new `GET /dms`, `list_workspace_threads`) merged client-side into one
  sidebar data model; unread/activity indicator per item reuses the existing `is_active`/
  `last_active_at`/`message_count` fields already on `sessions` — no new "unread" table; a
  client-side "last read message id" is stored in existing user preference storage
  (`localStorage` keyed by session id, consistent with how `lastMessageIdRef`/`?since=` replay
  already works for reconnect in `useSubscriptionTransport`).
- `/chat/[sessionId]` renders the same shared chat surface already used by
  `feature-workbench.tsx`'s `SessionChat` (subscription transport, `ThreadMembersPanel` toggle,
  message attribution) — parameterized by `kind`, not forked into a new component tree.
- **Migration/retirement (C5):** `/channels` and `/channels/[channelId]` routes become redirects
  to `/chat?section=channels` and `/chat/[sessionId]` respectively (Next.js redirect, not a hard
  delete) for one release, then removed; the standalone Team Chat nav entry and list route are
  retired the same way. `CreateChannelModal`/`ThreadMembersPanel` are relocated into the new
  `/chat` tree and reused as-is (no rewrite).
- New "start a DM" affordance: a member picker (reusing `listWorkspaceMembers`/`WorkspaceMember`
  from user-service, already available) in the Direct Messages section header; selecting a
  member calls `POST /dms` and navigates to the resolved/created session.

### 6. In-chat Board panel (G4) — read-only, reusing existing data layer
- A collapsible panel component in the shared chat surface (next to `ThreadMembersPanel`'s
  toggle) that renders a lightweight Kanban view (columns = task status) using the **existing**
  `use-sidebar-tasks.ts` hook and `board.ts` store, unmodified — no new endpoint, no new store.
- Auto-scoping: client-side regex/heuristic scans the visible message list for feature
  IDs/slugs (the same pattern the new `workflow_lookup_feature` tool parses server-side) and
  sets the board query's `feature_id` param to the most-recently-mentioned one; a manual
  "pin to feature" override in the panel header lets the user fix it explicitly, which simply
  sets the same `feature_id` param instead of the inferred one. No write actions are exposed
  (NG3) — cards are display-only, no drag/drop, no task mutation calls.
- This panel is available in **every** session kind (feature thread, Channel, Team Chat thread,
  DM) since it is purely a client-side read view keyed off whatever `feature_id` is inferred or
  pinned — it does not depend on the server-side tool-gating logic in §3.

## Dependency Analysis

- **hermes-agent** changes (kind='dm' migration + store functions, dispatch-gate branch,
  `workflow_lookup_feature` tool + `inject_context` branch, `POST/GET /dms` routes) are
  independent of each other internally but must land before the UI can call `/dms` or rely on
  the new tool — standard backend-before-frontend ordering, same as every prior v4 task wave.
- **workflow-backend**: no schema change required — the new lookup tool calls **existing** read
  endpoints (`GetWorkspaceBySlug`, feature detail, `GetDocumentContent`). This is a read-only
  consumer relationship, not a new dependency edge requiring a workflow-backend code change.
- **digital-factory-ui** changes (new `/chat` nav + sidebar shell, DM picker, board panel,
  route redirects) depend on the hermes-agent `/dms` endpoints and unchanged `listChannels`/
  `list_workspace_threads` — but the sidebar shell, board panel, and nav icon swap can be built
  and reviewed in parallel against mocked/existing endpoints, then wired to `/dms` last.
- **user-service**: no change required — `listWorkspaceMembers` already exists (T8) and is
  reused as-is for the DM member picker.

## Parallelization / Blocking Analysis

- **Wave 1 (parallel):**
  - hermes-agent: `kind='dm'` migration + `create_dm`/list store functions + `/dms` routes.
  - hermes-agent: `workflow_lookup_feature` tool implementation (independent of DM work — only
    touches `inject_context`'s `feature_id == ''` branch and a new read-only tool file).
  - digital-factory-ui: new `/chat` nav entry, sidebar shell, and route-redirect scaffolding
    (can be built against the **existing** `listChannels`/`list_workspace_threads` APIs without
    waiting on `/dms`).
  - digital-factory-ui: in-chat Board panel component (fully independent — reuses
    `use-sidebar-tasks.ts` unmodified, no dependency on any Wave 1 backend work).
- **Wave 2 (depends on Wave 1 hermes-agent DM work):**
  - digital-factory-ui: DM member picker wired to `POST/GET /dms`; Direct Messages section of
    the new sidebar wired to live data.
- **Wave 3 (cleanup, depends on Wave 1 UI shell being live):**
  - Retire `/channels` and Team Chat standalone routes → redirects; remove old nav-rail entries.
- **No blocking on workflow-backend or user-service** — both are read-only dependencies with no
  code changes required in this feature.
- **G6 (metering parity)** requires no dedicated task — it is validated by test coverage on the
  DM and lookup-tool paths asserting `check_quota`/`update_token_counts` are invoked identically
  to the existing feature-thread/Channel paths (regression tests alongside Wave 1/2 work, not a
  separate task).
