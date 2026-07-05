
# Product Specification

## Feature
- Feature ID: `activity-notifications-center`
- Title: Activity Center — In-App Notifications for Mentions, Messages, and Feature Lifecycle Events

## Problem

Today the product has two disconnected, partial notification stories and no unified way for a
user to answer "what happened that I need to look at?":

1. **Chat/mentions (`digital-factory-ui` + `hermes-agent`)** — `@mention` parsing and rendering
   already exist (`message.tsx:remarkMentions`, `mention-picker.tsx`), and the nav rail already
   computes a per-workspace unread count (`nav-rail.tsx:useWorkspaceUnreadCount` calling
   `chat.ts:getUnreadMentions`). But this is a **count only** — there is no feed a user can open
   to see *which* messages mentioned them, *which* channel had new activity, or *which* were DMs
   (per `agent-general-chat`) vs. `@mentions` vs. everything. There is no "mark as read" or
   settled read-state model beyond the ad-hoc unread count.
2. **Feature/task lifecycle (`workflow-backend` + `agent-workflow` orchestrator)** — a
   `workspace_activity_events` table and `GET /api/workspaces/:workspaceId/activity` endpoint
   already exist and already power a generic `ActivityFeed` component
   (`digital-factory-ui/pull/92`), but that feed is a **workspace-wide audit trail** rendered
   inside `TaskTrackingPanel` / `FeatureTabView` — it is not scoped to "things this user should
   be notified about," it has no unread/read state, and it is not delivered as a personal
   notification. Separately, `slack-thread-notifications` / `go-orchestrator-slack-notifications`
   already notify a **Slack channel** on feature start, handoff, and completion — but nothing
   notifies a human user **in-app** when a stage they care about (product spec, technical design,
   tasks) is approved, or when a task they own reaches `done`.

There is no single per-user "Activity" surface (the way Slack has an Activity tab with
All / DMs / Mentions), and no way for a user to control what they get notified about.

## Goals

- Add a personal **Activity** surface in `digital-factory-ui`, modeled after Slack's Activity tab,
  with three views: **All**, **DMs**, **Mentions**.
  - **Mentions** — messages where the current user was `@mentioned`, in a feature thread, a
    channel, or a workspace Team Chat thread (reuses the mention data already recorded by
    `hermes-agent`'s `messages` table / `author_id` + mention parsing).
  - **DMs** — new messages in the user's 1:1 Direct Message threads (per `agent-general-chat`).
  - **All** — the union: mentions, DM messages, **and** lifecycle notifications (below), in one
    reverse-chronological feed.
  - Each entry is markable read/unread; opening it navigates to the source thread, feature, or
    task. A nav-rail badge shows the current unread count (extending
    `useWorkspaceUnreadCount` / `getUnreadMentions` rather than replacing them).
- Notify a user in-app when:
  - Another user `@mentions` them in a feature thread, channel, or DM.
  - There is new activity (a message) in a channel they are a member of.
  - A feature's **product spec** is approved.
  - A feature's **technical design** is approved.
  - A feature's **tasks** stage is approved.
  - A task they are the assignee/owner of (or that they authored/are watching) reaches **`done`**.
- Let each user configure, per notification category, whether they want to be notified:
  at minimum **Mentions**, **Channel messages**, **DMs**, and **Feature lifecycle approvals**
  (spec/design/tasks approved), and **Task done**. Default: all categories on.
- Reuse existing event sources rather than re-deriving them:
  - Mention/DM/channel events come from `hermes-agent`'s existing `messages` /
    `session_members` / mention-resolution pipeline (the same pipeline that already backs
    `remarkMentions` and the mention-picker `@` typeahead).
  - Feature/task lifecycle events come from the same trigger points already instrumented for
    Slack (`agent-workflow` orchestrator's `feature-notification-watcher.ts` and the task
    notifier call sites in `dispatchExecutorResult`/`dispatchReviewResult`), and/or the existing
    `workspace_activity_events` table already populated by `workflow-backend` — extended with a
    per-user "who should be notified" fan-out, not a parallel event log.

## Non-goals

- Email, push, or any off-app delivery channel — this feature is in-app only. (Slack delivery for
  ops/feature-run visibility already exists via `slack-thread-notifications` /
  `go-orchestrator-slack-notifications` and is out of scope here — this is the *personal, in-app*
  surface.)
- Real-time delivery transport changes — this reuses whatever polling/SSE mechanism
  `digital-factory-ui` already uses for `useActivity` / chat streaming
  (`m3-agent-chat-v4`'s SSE fan-out); this feature does not introduce a new transport.
- Notification digesting/batching, snoozing, or do-not-disturb scheduling.
- Notifying on every `workspace_activity_events` audit action (e.g. `claimed`,
  `rag_pre_flight`, internal reviewer/fix-agent audit entries) — only the allowlisted lifecycle
  events named in Goals fan out to user notifications, mirroring the existing client-audience
  allowlist pattern from `m1-client-delivery-visibility`.
- Notification preferences at an org/workspace-admin level (e.g. forcing all members to be
  notified) — this feature is per-user, self-service settings only.

## Open questions (for technical design)

- Where should per-user notification preferences and the notification/read-state records live —
  `user-service` (owns user identity/settings today) vs. `hermes-agent` (owns messages/mentions)
  vs. `workflow-backend` (owns `workspace_activity_events` and feature/task lifecycle state)?
  Likely a split: `hermes-agent` fans out mention/DM/channel notifications (it already owns that
  data), `workflow-backend` fans out lifecycle notifications (it already owns stage/task status),
  and a shared per-user preferences store (candidate: `user-service`, since it is the identity
  system of record) gates both.
- How does the fan-out determine "who is watching" a feature/task for the approval and
  task-done notifications (feature members? task assignee? anyone who has visited it)? To be
  resolved in technical design against existing membership/assignment models.
