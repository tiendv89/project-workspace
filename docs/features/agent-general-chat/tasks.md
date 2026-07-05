
# Tasks — agent-general-chat

## Dependency diagram

```
T1 (hermes-agent: kind='dm' migration + store + /dms routes)
T2 (hermes-agent: dispatch gate — dm follows channel bare-message rule)  [depends: T1]
T3 (hermes-agent: workflow_lookup_feature read-only tool + inject_context branch)
T4 (hermes-agent: metering-parity regression tests for dm + lookup tool)  [depends: T1, T2, T3]

T5 (digital-factory-ui: new /chat nav entry + Slack-style sidebar shell, Channels+Threads sections wired to existing APIs)
T6 (digital-factory-ui: in-chat read-only Board panel component)
T7 (digital-factory-ui: DM member picker + Direct Messages section wired to /dms)  [depends: T1, T5]
T8 (digital-factory-ui: retire /channels + Team Chat standalone routes → redirects, remove old nav entries)  [depends: T5, T7]
```

## Index

| Task | Repo | Depends on | Actor |
|---|---|---|---|
| T1 | hermes-agent | — | agent |
| T2 | hermes-agent | T1 | agent |
| T3 | hermes-agent | — | agent |
| T4 | hermes-agent | T1, T2, T3 | agent |
| T5 | digital-factory-ui | — | agent |
| T6 | digital-factory-ui | — | agent |
| T7 | digital-factory-ui | T1, T5 | agent |
| T8 | digital-factory-ui | T5, T7 | agent |

---

## T1 — hermes-agent: `kind='dm'` migration + `create_dm`/list store functions + `/dms` routes

### Description
Add the additive DB migration widening `sessions.kind` to accept `'dm'` and the new
`idx_session_members_session_member` index (technical-design §1a). Implement
`src/db/store.py:create_dm` (resolve-or-create idempotent lookup for an unordered member
pair within a workspace, `feature_id=''`, `kind='dm'`) and a `list_dms` function mirroring
`list_workspace_threads`. Add `POST /dms` (`{other_member_id}`) and `GET /dms` endpoints to
`src/api/routers/threads.py` (or a new `dms.py` router alongside it).

### Required skills
- python-best-practices

### Subtasks
- [ ] Write migration file (next sequential number after latest v4 migration) per the exact SQL
      in technical-design §1a, plus the documented rollback script.
- [ ] Implement `create_dm(workspace_id, member_a, member_b)` — looks up an existing `dm` session
      for the unordered pair via the new index before inserting; returns existing session if found.
- [ ] Implement `list_dms(workspace_id, member_id)` — thin wrapper over `list_member_sessions`
      filtered to `kind='dm'`.
- [ ] Add `POST /dms` and `GET /dms` routes; validate `other_member_id` is a real workspace member
      (reuse existing membership validation pattern from `threads.py`).
- [ ] Unit tests: idempotent create (same pair twice returns same session), pair uniqueness
      across workspaces, listing scoped to caller.

---

## T2 — hermes-agent: dispatch gate — DM follows the Channel bare-message rule

### Description
Per technical-design §2: a `dm` session must **not** trigger the agent on a bare message —
only explicit `@agent` triggers, same as Channels. Add the one new conditional to the existing
dispatch-gate logic in `src/api/routers/messages.py` (or wherever `_should_trigger_agent`-
equivalent logic lives): `kind == 'dm'` behaves like `kind == 'channel'` for bare-message
purposes, while still allowing explicit `@agent`.

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `kind == 'dm'` to the no-bare-trigger branch alongside `kind == 'channel'`.
- [ ] Unit tests: `@agent` in a DM triggers exactly one turn; bare message in a DM triggers zero
      turns (mirroring `test_send_message_channel_bare_no_agent`).

---

## T3 — hermes-agent: `workflow_lookup_feature` read-only cross-feature tool

### Description
Per technical-design §3: new read-only tool registered in `plugins/tools/`, exposed to the
agent only when `session.feature_id == ''` (Channels, Team Chat threads, DMs). Parses a feature
ID/slug from the triggering message, resolves it via workflow-backend's existing feature-
resolution path (same HTTP path `plugins/db.py:get_feature_detail` uses), scoped to the caller's
own `workspace_id`. Returns title, stage/status, and a short synopsis from `product-spec.md`
(via the existing `DocumentHandler.GetDocumentContent` read path). Must not expose any write or
approval tool.

### Required skills
- python-best-practices

### Subtasks
- [ ] Implement `workflow_lookup_feature(feature_ref: str)` tool — parses/normalizes a feature
      ID/slug, calls workflow-backend read APIs scoped to the caller's workspace.
- [ ] Add the `if session.feature_id == '': tools += [workflow_lookup_feature]` branch in
      `plugins/hooks.py:inject_context`, symmetric to the existing feature-tool branch.
- [ ] Confirm the tool is absent from feature-scoped sessions' tool set (no duplication).
- [ ] Unit tests: successful lookup returns title/stage/synopsis; unknown feature ref handled
      gracefully; cross-workspace feature ref does not leak data; tool never appears alongside
      write tools in the same session's tool list.

---

## T4 — hermes-agent: metering-parity regression tests (G6)

### Description
Per technical-design §4, G6 is satisfied "by construction" since DM and lookup-tool turns run
through the existing `_run_agent_turn` → `update_token_counts` → `cost_client.check_quota`
pipeline. This task adds the regression coverage proving no bypass was introduced — it does not
add new metering logic.

### Required skills
- python-best-practices

### Subtasks
- [ ] Test: an `@agent` turn in a `dm` session invokes `update_token_counts` and
      `check_quota` identically (same call shape) to an equivalent Channel/feature-thread turn.
- [ ] Test: a turn that uses `workflow_lookup_feature` still hits `check_quota` — no discount,
      no bypass path for lookup-only turns.
- [ ] Test: no new/parallel cost-accounting function was introduced (assert `_run_agent_turn`
      remains the single entry point exercised by DM and lookup-tool turns).

---

## T5 — digital-factory-ui: new "Chat" nav entry + Slack-style sidebar shell

### Description
Per technical-design §5: add `ChatNavButton` to `nav-rail.tsx` (new `MessageSquare` icon,
distinct from the existing Channels Hash icon), routing to a new `/chat` route group. Build the
persistent left sidebar with three collapsible sections — Channels, Direct Messages, Threads —
backed initially by the existing `listChannels` and `list_workspace_threads` calls (Direct
Messages section can render empty/disabled state until T7 wires it to `/dms`). Implement
`/chat/[sessionId]` reusing the existing shared chat surface (`SessionChat` /
`useSubscriptionTransport`, `ThreadMembersPanel`) parameterized by `kind`, not forked.
Unread/activity indicator uses existing `is_active`/`last_active_at`/`message_count` fields plus
a client-side "last read message id" in `localStorage`.

### Required skills
- react-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `ChatNavButton` to `nav-rail.tsx` with new icon and `/chat` route.
- [ ] Build `/chat` layout with collapsible Channels / Direct Messages / Threads sections.
- [ ] Wire Channels and Threads sections to existing `listChannels`/`list_workspace_threads`.
- [ ] Implement `/chat/[sessionId]` reusing the existing shared chat surface component,
      parameterized by `kind` (no new component tree).
- [ ] Implement unread/activity indicator using existing session fields + `localStorage` last-
      read marker.
- [ ] Relocate `CreateChannelModal`/`ThreadMembersPanel` into the new `/chat` tree, reused as-is.
- [ ] Tests: sidebar renders all three sections; nav entry visible; type-check/lint clean.

---

## T6 — digital-factory-ui: in-chat read-only Board panel

### Description
Per technical-design §6: a collapsible panel in the shared chat surface (next to
`ThreadMembersPanel`'s toggle) rendering a read-only Kanban view (columns = task status) using
the **existing** `use-sidebar-tasks.ts` hook and `board.ts` store, unmodified. Auto-scopes to
the most-recently-mentioned feature ID/slug found in the visible message list (client-side
regex/heuristic); manual "pin to feature" override in the panel header. No write actions,
no drag/drop, no task mutation calls (NG3). Available in every session kind.

### Required skills
- react-best-practices
- typescript-best-practices

### Subtasks
- [ ] Implement panel toggle in the shared chat surface, alongside `ThreadMembersPanel`.
- [ ] Implement feature-ID/slug detection heuristic over visible messages to auto-set
      `feature_id` param passed to `use-sidebar-tasks.ts`.
- [ ] Implement manual "pin to feature" override in the panel header.
- [ ] Render columns by task status, display-only (no drag/drop, no mutation calls).
- [ ] Tests: auto-scoping picks the most recent mention; pin override takes precedence; panel
      renders in feature thread, Channel, Team Chat thread, and DM contexts alike.

---

## T7 — digital-factory-ui: DM member picker + Direct Messages section wired to `/dms`

### Description
Per technical-design §5: add a member picker (reusing `listWorkspaceMembers`/`WorkspaceMember`
from user-service, already available) in the Direct Messages section header of the new `/chat`
sidebar. Selecting a member calls `POST /dms` (resolve-or-create) and navigates to the resulting
session. Wire the Direct Messages section's list to `GET /dms`.

### Required skills
- react-best-practices
- typescript-best-practices

### Subtasks
- [ ] Implement member picker UI using existing `listWorkspaceMembers`.
- [ ] Wire "start a DM" action to `POST /dms`; navigate to the resolved/created session.
- [ ] Wire Direct Messages sidebar section to `GET /dms`.
- [ ] Tests: selecting an existing DM partner reopens the same session (idempotent); new partner
      creates a new session; Direct Messages section reflects live data.

---

## T8 — digital-factory-ui: retire `/channels` + Team Chat standalone routes → redirects

### Description
Per technical-design §5 / constraint C5: once the new `/chat` section (T5) and DM wiring (T7)
are live, convert `/channels` and `/channels/[channelId]` into redirects to
`/chat?section=channels` and `/chat/[sessionId]` respectively (not a hard delete, to avoid
breaking existing deep links), and retire the standalone Team Chat nav entry/list route the
same way. Remove the old duplicate nav-rail entries once redirects are confirmed working.

### Required skills
- react-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add Next.js redirects: `/channels` → `/chat?section=channels`,
      `/channels/[channelId]` → `/chat/[sessionId]`.
- [ ] Add redirect for the standalone Team Chat list route to the new `/chat` Threads section.
- [ ] Remove old Channels and Team Chat nav-rail entries from `nav-rail.tsx`.
- [ ] Tests: old deep links redirect correctly (no 404s); nav rail shows only the new unified
      Chat entry.
