# Product Specification

## Feature
- Feature ID: `m3-agent-chat-history`
- Title: Agent Chat History — Session List, Resume, and New Chat

## Background
`m3-agent-chat` shipped a right-panel chat UI for conversing with the agent while authoring
feature artifacts. By design (NG3 in that spec), chat context lived only in the browser
session: a page refresh discarded the conversation and the next mount always started fresh.

The hermes-agent workflow_gateway introduced in `m3-agent-chat` already persists sessions and
messages to Postgres (`sessions`, `messages` — see `database/hermes-agent/schema.dbml`). The
storage exists — it is just not surfaced in the UI. This feature closes that gap.

## Problem
Users lose their conversation context every time they navigate away from a feature page or
refresh the browser. There is no way to:
- Resume a prior conversation thread with the agent.
- See what was discussed or drafted in an earlier session.
- Start a clean conversation without refreshing the page.
- Know which session is active or how old it is.

This creates friction during iterative drafting: if a user spent 10 minutes converging on a
product spec draft with the agent and then navigates away, the entire context is gone.

## Goals
- **G1** — On load, automatically resume the user's most recent session for the current
  feature instead of always creating a new one.
- **G2** — Provide a **New Chat** action that creates a fresh session without requiring a
  page reload.
- **G3** — Provide a **session history list** that shows the user's past sessions for the
  current feature (title or first-message preview + relative timestamp).
- **G4** — Selecting a session from the history list loads that session's message thread
  into the chat panel.
- **G5** — The active session is visually indicated in the history list.

## Non-goals
- **NG1** — This feature does not implement cross-feature or cross-workspace history. History
  is scoped to the current workspace + feature.
- **NG2** — This feature does not implement search or filtering of session history.
- **NG3** — This feature does not implement session deletion or renaming by users in v1.
- **NG4** — This feature does not implement shared sessions (multi-user viewing the same
  session). Sessions remain single-user.
- **NG5** — This feature does not change how messages are stored — Postgres persistence
  is already in place from `m3-agent-chat`.

## User Flow

### Loading a feature page (returning user)
1. User navigates to a feature they previously chatted on.
2. The chat panel loads and queries for the user's most recent session.
3. The previous message thread is restored in the panel without the user doing anything.
4. A subtle indicator (e.g. relative timestamp: "Resumed · 2 hours ago") confirms the
   session was restored rather than started fresh.

### Starting a new chat
1. A **New Chat** button is visible at the top of the chat panel (or in the history drawer).
2. User clicks **New Chat**.
3. A new session is created; the message thread clears.
4. The prior session is preserved in history and can be returned to.

### Viewing and selecting history
1. A **History** icon or label is visible in the chat panel header.
2. Clicking it opens an inline list (or slide-over drawer) showing past sessions for
   this feature, each with a first-message preview and relative timestamp.
3. The currently active session is highlighted.
4. Clicking a past session loads its message thread into the chat panel.
5. The user can dismiss the list and return to the active session.

## Success Criteria
- Navigating to a feature page that has prior chat sessions automatically restores the
  most recent one — no manual action required.
- Clicking **New Chat** clears the thread and starts a new session; the old session
  remains accessible in history.
- The history list shows at least the last 10 sessions with a preview and timestamp.
- Selecting a session from history loads its full message thread in under 500 ms (p95).
- No regressions to the chat panel's streaming, slash-command picker, or artifact-saved
  refresh from `m3-agent-chat`.

## Reference
- Predecessor feature: `docs/features/m3-agent-chat/` — gateway architecture, SSE
  envelope, session Postgres schema.
- hermes-agent fork: `/Users/pye/code/voyager/hermes-agent` — gateway session API
  (`workflow_gateway/api/router.py`) and Postgres session store.
- voyager-interface chat UI components:
  `/Users/pye/code/voyager/voyager-interface/src/components/intelligence/agent/`
