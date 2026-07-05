
# Product Specification

## Feature
- Feature ID: `agent-general-chat`
- Title: General Chat, Direct Messages, Cross-Feature Agent Context, and a Unified Chat Hub

## Problem

The M3 agent-chat line (`m3-agent-chat` → `v4`) already shipped a lot of "Slack where some of
the assignees are agents":

- **Feature threads** — a session with `feature_id` set, members, `@mention`, live SSE delivery
  (`hermes-agent` `sessions`/`messages`, `digital-factory-ui` `feature-workbench.tsx`).
- **Channels** — public, workspace-scoped, admin-managed spaces (`sessions.kind='channel'`,
  `feature_id=''`), with a **Channels** nav-rail entry (`src/components/shell/nav-rail.tsx`,
  Hash icon, `/channels` route), list/create/admin-delete pages, and `ThreadMembersPanel`
  (`digital-factory-ui/pull/136`).
- **Workspace Team Chat threads** — ad-hoc, membership-scoped threads not born from a feature
  (`kind='thread'`, `feature_id=''`, `hermes-agent` T9 `POST /threads`), with their own nav entry
  and list/create page (`digital-factory-ui` T10, `pull/547`).

Three gaps remain, all called out explicitly in this request:

### 1. The agent is context-blind outside its own feature thread
`m3-agent-chat-v4`'s dispatch design (§4.2, NG12) **deliberately omits feature tools from channel
context** — the agent in a Channel or a workspace Team Chat thread has no `feature_id` to scope
against, so it cannot answer "what does feature VOY-59 do?" the way it can inside that feature's
own thread. There is no read-only, cross-feature lookup path available to the agent when it is
triggered (`@agent`) in a general-purpose (non-feature) session. Users have to leave the general
chat, open the feature, and ask there — defeating the point of a general space.

### 2. There is no Direct Message (1:1) surface
Today membership-scoped, non-feature conversation means either a public **Channel** (visible to
the whole workspace, admin-managed) or a **workspace Team Chat thread** (ad-hoc, but still a
multi-member "group" concept surfaced as a flat list). There is no lightweight **person ↔ person**
DM the way Slack has one — pick a teammate, get a private 1:1 thread, done. `user-service` already
exposes `listWorkspaceMembers` / `WorkspaceMember` (added in T8) but nothing in `hermes-agent` or
`digital-factory-ui` lets a user start a 1:1 conversation from that member list.

### 3. Chat surfaces are fragmented across the nav rail, not a unified hub
Channels and Team Chat shipped as **two separate, siloed nav-rail entries** — each its own icon,
its own list page. There is no single "Chat" destination the way Slack has one left-rail icon
that opens a sidebar of Channels + DMs + threads together. Discovery is poor: a new user has to
know to look in two different places, and there's no unread/activity signal unifying them.

### 4. No way to see task/feature board context from inside a chat
When a channel or thread discussion references a feature, task, or board item, the only way to
check status is to leave chat entirely and open the Tasks/Board view (`src/stores/board.ts`,
`src/hooks/board/use-sidebar-tasks.ts`). There is no in-chat way to glance at a board scoped to
what's being discussed.

## Goals

- **G1 — Cross-feature, read-only agent context in general chat.** When the agent is triggered
  (`@agent`) inside a Channel or a workspace Team Chat thread (any session with `feature_id=''`),
  it gains a **read-only, cross-workspace lookup tool** — given a feature ID/slug mentioned in the
  message (e.g. "VOY-59"), it can resolve and summarize that feature's title, stage/status, and a
  short synopsis from its `product-spec.md` — without gaining the full feature-scoped tool set
  (no writes, no task mutation, no document authoring) that a feature thread gets. This directly
  closes the gap left by `m3-agent-chat-v4` NG12.
- **G2 — Direct Messages (1:1).** A user can start a private, 1:1 thread with any other workspace
  member from a member picker. A DM is modeled as a **2-human-member thread** (`sessions.kind`
  gets a new `dm` value, reusing the existing thread member-set machinery from v4) plus the
  resident agent, so `@agent` still works inside a DM exactly as it does in a Team Chat thread.
  Only the two participants (never the whole workspace) can see a DM.
- **G3 — One unified "Chat" hub in the left nav, Slack-style — a genuinely new section.**
  This is **not** a rename or reskin of the existing `/channels` or Team Chat pages — it is a
  **new top-level nav-rail section** (new route, e.g. `/chat`; new icon distinct from the
  existing Hash icon) that stands entirely on its own. It opens a Slack-like sidebar with three
  sub-sections: **Channels**, **Direct Messages**, **Threads** (workspace Team Chat threads,
  unchanged behavior) — each with an unread/activity indicator. Creating a Channel, starting a
  DM, or starting a Team Chat thread all happen from this one new hub. The existing **Channels**
  and **Team Chat** nav-rail entries and their standalone list pages (`/channels`,
  `/channels/[channelId]`, the T10 Team Chat list route) are **retired** once the new section
  ships — their data and APIs are reused, but the entry points are consolidated into the new
  `/chat` section, not left as parallel duplicate nav items.
- **G4 — Smart in-chat board view.** Any channel, thread, or DM can render an inline, collapsible
  **Board panel** scoped automatically to whichever feature ID(s) have been mentioned/discussed
  in that conversation (reusing the existing board data layer — `use-sidebar-tasks.ts` /
  `board.ts` store) — a lightweight Kanban-style read view (columns by task status) without
  leaving the chat surface. A manual override lets a user pin the panel to a specific feature ID.
- **G5 — Existing lifecycle and thesis guardrails are preserved.** The agent remains
  **triggered, never self-dispatching** in every new surface (DM, general lookup) — same
  explicit-`@agent` gate as Channels/Team Chat from v4. The new cross-feature lookup tool is
  strictly read-only; it never mutates lifecycle state, tasks, or documents. Channels remain
  admin-deletable/public; DMs and Team Chat threads remain member-managed as today.

## Non-goals

- **NG1** — No write/mutation access from general chat. The agent's cross-feature lookup (G1)
  never approves stages, edits documents, or mutates tasks — that remains exclusive to a
  feature's own thread, same as today's guardrail.
- **NG2** — No group DMs (3+ humans, no channel). That use case is already served by workspace
  Team Chat threads (v4); DMs here are strictly 1:1.
- **NG3** — No board **editing** from the in-chat panel (G4) — it is read-only status/columns
  view. Editing a task still happens in the full Tasks/Board page.
- **NG4** — No change to feature-thread behavior, `@mention` semantics, message attribution,
  or the SSE/subscription transport shipped in v4 — this feature only adds new surfaces and a
  narrow read-only context tool.
- **NG5** — No cross-workspace chat; DMs, Channels, and Threads all remain scoped to a single
  workspace, consistent with existing `workspace_id` scoping.
