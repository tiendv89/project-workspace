# Product Specification

## Feature
- Feature ID: `m3-agent-chat-v4`
- Title: Agent Chat v4 — The Thread: Team Chat, Channels, @mention, and a Triggered Agent

## Background

The M3 agent-chat line has turned the digital-factory-ui into a place where a human and the
hermes-agent co-author a feature's artifacts through conversation. Every iteration so far has
been **1:1** — one user talking to one agent:

- **v1 (`m3-agent-chat`)** — the chat panel and the streaming generation loop; the agent reads
  workspace context and writes `product-spec.md` / `technical-design.md`.
- **v2 (`m3-agent-chat-v2`)** — persistent session history, context-rich agent tools (live
  tasks, GitNexus, RAG), and the three-panel IDE-style layout.
- **v3 (`m3-agent-chat-v3`)** — conversational document authoring as the core loop:
  PR-tracked commits, live preview, light manual edits, and in-chat, store-aware approval. The
  agent loads the relevant skills and knows how to draft and iterate a product spec / technical
  design end to end.

**v4 delivers the M3 milestone headline — "The Thread."** The roadmap describes M3 as *the
thesis made real: Linear/Slack where some of the assignees are agents* — a collaborative chat
surface with real-time transport where humans and a Hermes agent work a feature together, you
`@mention` a person or the agent, the agent participates and posts back, and **humans still
gate.** The roadmap's explicit guardrail (the thesis "trap") governs the whole feature: *chat
drafts and discusses; skills mutate state; permissioned actors gate; agents are triggered,
never self-dispatching from chatter.*

This is the moment the product stops being "a human directing an agent" and becomes **a team
working on a feature whose members happen to be human or agent.** v4 makes the session a shared
**thread**: multiple human members and the resident Hermes agent in one conversation, each
message attributed to its author, delivered live, and addressed by `@mention`.

## Scope decisions (locked at product-spec time)

These forks were decided up front and bound the rest of the spec:

- **Real-time transport — in.** Messages, agent posts, and activity indicators stream live to
  all thread members; the thread is instantaneous, not refresh-driven. (Matches the milestone's
  "real-time transport" line.)
- **Participants — humans + one Hermes agent.** A thread's members are human workspace members
  plus the single resident Hermes agent (addressed as **`@agent`**). You `@mention` a person
  (in-app notify) or `@mention` the agent (trigger it). **Any thread member may add or remove
  members**, and membership is explicit — workspace membership alone does not grant thread
  access. Delivery roles (PO / Architect / Reviewer / QC) appear as **labels**
  on members only — **role-gated authority and multiple role-agents stay deferred to M5.**
- **Notifications — in-app only.** A `@mentioned` human gets an in-app mention / unread
  indicator. No Slack or email wiring in v4 (that is a separate follow-on; see References).
- **Channels — in, as parallel workspace spaces.** Alongside per-feature session threads, v4
  adds **Channels**: named, persistent, workspace-level team chat spaces shown in their own
  "Channels" section (not tied to any feature). **Any workspace member can create a channel;
  only admins can delete one;** channels are **public** (any workspace member may join and post);
  and they reuse the full team-chat surface — attribution, real-time delivery, `@mention`, and the
  triggered-only `@agent`.

## Problem

### The conversation has room for only one human and always-on agent
The chat is single-user and single-agent. A colleague cannot join the conversation a teammate
is having with the agent, and the agent — being the only other party — replies to *every*
message. There is no notion of a **team in the thread**, no way to bring a second person in, and
no way to address one specific participant. The product models "a human and an agent," not "a
team on a feature."

### There is no way to address a specific participant
With only two parties, addressing is implicit. The moment a thread has several humans and the
agent, every message is ambiguous: who is it for? There is no `@mention` — no way to direct a
question at a named teammate, or to call the agent in to do a piece of work, while leaving the
rest of the conversation as human-to-human discussion.

### The agent has no trigger discipline
In a 1:1 the agent answers everything, which is fine. In a team thread that behaviour is both
noisy and a **guardrail violation**: the agent would barge into human-to-human discussion and
effectively self-dispatch from chatter. The thesis is explicit that agents must be *triggered,
never self-dispatching*. There is currently no mechanism that lets humans talk amongst
themselves in the thread without waking the agent, and no explicit signal ("@the agent") that
constitutes a deliberate trigger.

### Sessions have no membership or shared-visibility model
A session today belongs to whoever created it; there is no concept of a session that several
people are **members of** and can **see and post in**. Collaboration needs exactly that — an
explicit member set and a shared-visibility model — and none exists. Without it there is no way
to bring a teammate into a conversation or to know which threads a given person is part of.

### Messages are not attributed and do not arrive live
Because there was only ever one human, messages carry no meaningful author identity in the UI,
and there is no real-time delivery — a second person would not see a message or an agent post
appear until they refreshed, with no indication that someone is typing or that the agent is
working. A multi-party transcript is unreadable and unusable without per-message attribution
and live updates.

### Team conversation is locked to features
Every conversation lives inside a feature's session. There is no workspace-level place for the
team to talk — standing topics, cross-feature coordination, announcements, or a general space —
and no way for an admin to organize team chat into named **channels** the way every team tool
does. Discussion that isn't about one specific feature has nowhere to live.

## Goals

- **G1 — Threads have members.** A session is a **thread** with an explicit member set:
  one or more human workspace members plus the resident Hermes agent. **Any member of a thread
  may add or remove members** — membership is explicit (workspace membership alone does **not**
  grant access to a thread; a member must be added). The member list is visible in the thread.
- **G2 — `@mention` people and the agent.** A user can `@mention` any human member of the thread
  or the Hermes agent (addressed as **`@agent`**) via an inline typeahead picker. The mention is
  rendered as a distinct token in the posted message and resolves to a real participant.
- **G3 — The agent is triggered, never self-dispatching.** The Hermes agent posts back **only on
  an explicit `@agent` mention** (a plain reply to one of its messages does **not** re-trigger it;
  resolved OQ2). In a feature thread a bare message counts as an implicit `@agent` (v3 back-compat);
  in a channel a bare message does not. Human-to-human messages never wake the agent. This makes
  the thesis guardrail concrete: humans can discuss freely; the agent acts only on a deliberate
  trigger.
- **G4 — Real-time delivery.** Human messages, agent posts, and activity indicators (a member
  typing; "the agent is working") stream live to every thread member over a real-time transport,
  so the conversation is instantaneous and shared — no refresh required.
- **G5 — Attributed messages.** Every message in the thread displays its author — human name /
  avatar, or the Hermes agent clearly marked as the agent — so a multi-party transcript is
  readable and the agent's contributions are unambiguously the agent's.
- **G6 — In-app mention & unread indicators.** A human who is `@mentioned` sees an in-app
  indicator (mention badge / unread marker) drawing them to the thread. No external (Slack /
  email) notification is sent in v4.
- **G7 — Threads are discoverable by their members.** A thread is reachable and resumable by
  every human member from the session/history surface — a user sees the threads they own and the
  threads they have been added to, so collaboration is visible without exposing sessions they are
  not part of.
- **G8 — Humans still gate; the surface only drafts and discusses.** The collaboration thread
  changes nothing about who may mutate state. v3's authoring and approval semantics carry over
  unchanged: the agent drafts and discusses; state-changing actions (approve / reject /
  rollback, document commits) remain human-gated, surfaced affordances. Agents prepare and
  surface; they do not approve, and they do not self-dispatch.
- **G9 — Role labels on members (display only).** Members may carry a delivery-role label
  (PO / Architect / Reviewer / QC) shown next to their name in the thread. Labels are
  presentational in v4 and confer **no** authority — role-gated permissions remain an M5 concern.
- **G10 — Workspace-level Channels.** v4 adds **Channels**: named, persistent, workspace-level
  team chat spaces shown in a dedicated "Channels" section alongside per-feature sessions. A
  channel is not tied to a feature. Channels reuse the same team-chat surface as feature threads
  — attributed messages, real-time delivery (G4/G5), `@mention` of members or the `@agent`, and
  the triggered-only agent discipline (G3).
- **G11 — Open creation, admin-gated deletion; public membership.** **Any workspace member may
  create** a channel; **only admins may delete** one. Channels are **public**: any workspace
  member may join and post. Deletion is the only admin-gated action; creating, joining, and
  posting are open to every workspace member.

## Non-goals

- **NG1 — No multiple agents / role-agents.** Exactly one resident Hermes agent participates.
  Distinct per-role agents (reviewer-agent ≠ implementer-agent) and identity separation are out
  of scope (M5).
- **NG2 — No role-gated authority or agent self-dispatch.** Roles are labels (G9); v4 grants no
  agent the ability to gate, approve, or self-dispatch within a granted authority. That is the
  M5 North Star and is explicitly excluded here.
- **NG3 — No external notifications.** Slack / email / push notification on `@mention` is out of
  scope for v4 (in-app only — G6). Reusing `slack-thread-notifications` for human mentions is a
  separate follow-on.
- **NG4 — No real-time collaborative document editing.** v3's NG3 still holds: the document
  preview/edit surface remains single-writer-at-a-time with read-before-write conflict
  detection. v4 adds real-time to the **chat thread**, not to the artifact editor.
- **NG5 — No sub-threads, replies-as-threads, or DMs.** The thread is flat. No nested threading,
  no private direct messages between a subset of members, no per-message reply chains.
- **NG6 — No message editing, deletion, or reactions.** Posted messages are immutable in v4;
  emoji reactions, edits, and per-message deletes are not in scope.
- **NG7 — No external / guest participants.** Members are workspace members only. No cross-
  workspace membership and no unauthenticated guests.
- **NG8 — No new approval semantics.** As in v3, `review_status` values, transitions, and the
  human-only approval rule are unchanged. v4 only changes *who is in the room*, not *who may
  gate*.
- **NG9 — No change to v3 document authoring / PR pipeline.** Conversational authoring, the
  PR-tracked commit pipeline, live preview, and light editing ship as-is; v4 wraps them in a
  multi-member, real-time thread.
- **NG10 — Non-admins cannot delete channels.** Channel **deletion** is admin-only. Any member
  may create, join, and post in channels; only deletion is gated.
- **NG11 — No private or DM channels in v4.** Channels are public workspace spaces. Private
  (invite-only) channels and direct-message channels are out of scope — private collaboration
  still happens in feature threads with explicit membership.
- **NG12 — v3 document authoring / approval stays feature-thread-scoped.** The conversational
  authoring, PR pipeline, and in-chat approval affordances operate on a feature's artifacts and
  are **not** available in workspace channels (a channel is not tied to a feature). In a channel
  the agent converses; it does not author feature documents or gate lifecycle state.
- **NG13 — No channel rename, archive, categories, or nesting in v4.** Channels are a flat list
  created and deleted by an admin; renaming, archiving, grouping into categories, and nested
  channels are out of scope.

## User Flows

### Bringing a teammate into the thread
1. A user is drafting a spec with the agent in a thread.
2. They open the thread's member list and add a colleague (a workspace member).
3. The colleague now sees the thread in their history (G7) and can open it, read the full
   transcript with attribution (G5), and post.

### Calling the agent in to do work
1. In a thread with two humans and the agent, the humans discuss an approach amongst themselves;
   the agent stays silent (G3).
2. When they're ready, one user types `@` — a picker lists the thread's human members and the
   Hermes agent — and selects the agent: *"@agent draft the product spec from what we just
   agreed, three goals."*
3. The message posts, attributed to that user; the agent is triggered, an "agent is working"
   indicator appears live for all members (G4), and the agent posts its result back into the
   thread, attributed to the agent.

### Addressing a teammate (agent stays out of it)
1. A user types `@` and selects a human member: *"@dana can you confirm the export format before
   we lock the spec?"*
2. The message posts and is delivered live to all members. Dana gets an in-app mention indicator
   (G6). The agent is **not** triggered and posts nothing (G3).

### Watching the thread live
At all times, members see each other's messages and the agent's posts appear in real time, with
a typing indicator when someone is composing and an "agent is working" indicator while the agent
runs a turn (G4) — no refresh needed.

### Approving inside a shared thread
1. The agent has prepared the spec; per v3 it surfaces the approve/reject affordance in the
   thread.
2. A human member with the right to gate clicks **Approve**; the v3 store-aware lifecycle
   transition runs exactly as before (G8). Other members see the state update live. The agent
   did not and could not approve.

### Talking in a channel
1. A workspace member creates a channel from the Channels section (e.g. `#general`, `#design`).
2. Any workspace member opens the channel, joins, and posts; messages are attributed and
   delivered live to everyone viewing (G4, G5).
3. A member `@mentions` the `@agent` in the channel to pull it in; the agent is triggered and
   posts back, exactly as in a feature thread. Human-to-human messages do not wake it (G3).

### Managing channels
Any member creates a new channel from the Channels section. Deleting a channel that is no longer
needed is an **admin-only** action; non-admins can create, join, and post but cannot delete
channels (G11, NG10).

## Scope

### In scope

**Thread membership & shared visibility (backend + UI)**
- A **membership model** on sessions/threads: a thread has an owner and a set of human members
  plus the Hermes agent. Add / remove member operations.
- A member-aware session/history listing so a user sees **the threads they own and the threads
  they have been added to** (G7).
- Member-list UI in the thread; role-label display on members (G9).

**`@mention` (UI + backend)**
- An inline `@` **typeahead picker** in the composer listing the thread's human members and the
  Hermes agent; selection inserts a resolvable mention token.
- **Mention parsing & resolution** on the backend: extract mentions from a posted message,
  resolve them to participant identities, persist mention records, and use them to drive both
  agent triggering (G3) and recipient indicators (G6).
- Distinct rendering of mention tokens in the message transcript.

**Triggered-agent dispatch (backend + hermes-agent)**
- A dispatch gate: the agent turn is invoked **only** on an explicit `@agent` mention (a plain
  reply does not re-trigger; a bare message triggers in a feature thread but not a channel).
  Human-to-human messages persist and broadcast but do **not** invoke the agent.
- The agent consumes the **multi-author thread context** when triggered (it must read a
  conversation with several human authors, not a 1:1 transcript) and posts its reply attributed
  to the agent.
- Trigger discipline is enforced server-side, not left to the agent's own judgement — the agent
  cannot self-dispatch from chatter (guardrail).

**Real-time transport (backend + UI)**
- A real-time channel delivering, to every thread member: new human messages, agent posts,
  agent token-stream / "agent is working" status, and lightweight typing indicators (G4).
- Fan-out to all current members of a thread (not just the message author's own stream as in the
  1:1 model).

**Attribution & indicators (UI)**
- Per-message author identity (human name/avatar; agent clearly marked) across the live thread
  and the persisted transcript (G5).
- In-app **mention / unread indicator** for a member who is `@mentioned` (G6).

**Channels (UI + backend)**
- A **Channels** section in the workspace navigation listing the workspace's channels, separate
  from the per-feature session list.
- **Create channel** (open to any workspace member) and **delete channel** (admin-gated)
  operations; a channel has at least a name (description optional).
- A channel conversation surface that **reuses the full team-chat stack** built for feature
  threads: join/membership, attributed messages, real-time fan-out, `@mention` + `@agent`
  triggered dispatch, and in-app mention indicators.
- Public membership: any workspace member may open, join, and post in any channel (G10, G11).

### Out of scope (tracked separately)
- External notifications (Slack/email) on mention — follow-on building on
  `slack-thread-notifications`.
- Multiple / role-specific agents and any agent authority or self-dispatch (M5).
- Real-time collaborative editing of the document artifacts (stays single-writer — v3 NG3).
- Sub-threads, DMs, reactions, message edit/delete.
- Cross-workspace / guest participants.
- Private / invite-only channels and direct-message channels (channels are public in v4).
- Channel rename / archive, channel categories or nesting, and per-channel notification
  preferences.
- v3 document authoring / approval inside channels (stays feature-thread-scoped — NG12).

## Skills and agent tools

v4 is primarily a **collaboration-surface and transport** feature; it does not reinvent the
authoring or lifecycle mechanics from v3. It reuses them inside a multi-member thread.

**Reused, unchanged from v3 (still human-gated):**
- The document-generation/edit tool + PR pipeline, live preview, and light editing.
- `approve-feature` / `reject-feature` / `set-feature-stage` (store-aware) behind the in-chat
  approval / rollback affordances — humans gate (G8).
- `resolve-project-env`, `pr-create`, and the GitHub adapter for any git/PR work.

**New for v4:**
- A **membership** capability on the session/thread store (add/remove members; member-aware
  listing).
- A **mention** capability: parse, resolve, persist mentions; derive trigger + recipient
  signals.
- A **triggered-dispatch** path that invokes the Hermes agent only on an `@mention` of the agent
  and feeds it the multi-author thread context.
- A **real-time fan-out** transport delivering messages and indicators to all thread members.
- UI: `@` picker, attributed multi-author transcript, member list with role labels, live
  indicators, and the in-app mention/unread indicator.

## Open Questions — RESOLVED

All open questions are resolved. See `technical-design.md` → "Resolved decisions" for the
implementation detail.

- **OQ1 — Real-time transport → SSE.** A persistent per-thread SSE subscription + plain POST to
  send; in-process pub/sub for v4 (single hermes instance per workspace), swappable to Postgres
  `LISTEN/NOTIFY` / Redis at scale; reconnect uses a `?since=` replay.
- **OQ2 — Agent trigger → explicit `@agent` only, coalesced.** A plain reply does not re-trigger;
  multiple `@agent` mentions during a turn coalesce into one follow-up turn.
- **OQ3 — Human mention disambiguation → unique handle.** The display name is shown; a unique
  handle/username (from user-service) disambiguates duplicates. (Agent = `@agent`.)
- **OQ4 — Concurrency / bare-message default → container-aware.** A bare message triggers the
  agent in a feature thread but not in a channel; agent turns serialize per session; message
  ordering is by server receipt; v3 read-before-write doc safety is unchanged (one writer at a
  time on the artifact — NG4).
- **OQ5 — Presence → transient indicators only** (typing / "agent is working"); no who's-online
  presence.
- **OQ6 — Notification model → open-clears + aggregate.** Opening a thread/channel clears all its
  unread mentions; per-thread/channel badge plus a workspace-level aggregate count in the nav.
- **OQ7 — Channel admin & deletion → admin-only hard delete.** Creation is open to any member;
  deletion is gated to the workspace admin role (resolved against the identity model in T5);
  deletion is a **hard delete** (messages cascade); channel name is unique per workspace; an
  optional seeded `#general` may exist; no channel is undeletable.
- **OQ8 — Agent context in a channel → workspace-scoped.** When `@mentioned` in a channel the
  agent operates with workspace-scoped context; feature authoring/approval tools stay inert
  (NG12), enforced by the channel having no `feature_id`.

## Success Criteria

- Two or more human members and the Hermes agent can participate in one thread; every message is
  attributed to its author and delivered live to all members without a refresh.
- The `@` picker lists the thread's human members and the agent; selecting one inserts a
  resolvable mention rendered distinctly in the transcript.
- `@mentioning` the agent triggers a posted-back agent response; messages between humans that do
  **not** mention the agent never trigger it (guardrail verified).
- A human who is `@mentioned` sees an in-app mention/unread indicator; no Slack or email is sent.
- A user can see and resume the threads they own and the threads they have been added to, and
  can open a shared thread from the session/history surface.
- v3 conversational authoring, the PR-tracked commit pipeline, and store-aware in-chat approval
  all continue to work inside a shared thread; only humans gate state, and members see state
  changes live.
- Any workspace member can create a channel and open, join, and post in one, with messages
  attributed and delivered live; only admins can delete a channel (non-admins cannot).
- `@mentioning` the `@agent` in a channel triggers a posted-back response under the same
  triggered-only discipline; human-to-human channel messages never trigger it.
- Lint, type-check, and the full test suites of the touched repos pass before any PR.

## Reference
- Roadmap milestone: `docs/roadmap-milestone.md` → **M3 — The Thread** (collaborative chat +
  real-time transport, `@mention` a person or a Hermes agent, humans gate; guardrail: *agents
  are triggered, never self-dispatching from chatter*). Also M2 (the resident single Hermes
  teammate this thread addresses) and M5 (role-gated authority / agent self-dispatch — explicitly
  deferred).
- v1 spec: `docs/features/m3-agent-chat/product-spec.md`
- v2 spec: `docs/features/m3-agent-chat-v2/product-spec.md` (three-panel layout, sessions,
  context tools)
- v3 spec: `docs/features/m3-agent-chat-v3/product-spec.md` (conversational authoring, PR-tracked
  commits, in-chat approval — the loop v4 makes multi-member)
- Related but out of scope: `docs/features/slack-thread-notifications/` (external notification
  surface a later version could wire to human `@mentions`)
- Guardrail source: `product-thesis.md` ("the trap" — chat drafts and discusses; skills mutate
  state; permissioned actors gate; agents are triggered, never self-dispatching).
- Touched repos (subject to technical design): `digital-factory-ui` (thread UI, `@` picker,
  attribution, live indicators, mention indicator), `workflow-backend` and/or `workflow-bff`
  (membership, mention parsing/resolution, triggered dispatch, real-time fan-out),
  `hermes-agent` (trigger discipline, multi-author context consumption), and `user-service`
  (member identity resolution for mentions, and the **admin-role check** gating channel
  deletion). Channels add a Channels section to `digital-factory-ui` and channel
  CRUD + membership to the `workflow-backend` / `workflow-bff` layer, reusing the same
  team-chat transport and dispatch components as feature threads.
