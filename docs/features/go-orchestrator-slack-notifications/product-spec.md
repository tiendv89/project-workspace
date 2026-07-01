# Product Specification

## Feature
- Feature ID: `go-orchestrator-slack-notifications`
- Title: Go Orchestrator Slack Notifications (bot-token, threaded)

## Problem
The TS orchestrator delegates go-feature Slack notifications to the Go orchestrator
(`notification-watcher.ts` skips `owner='go'` with the comment *"Go-owned features: Slack
notifications are handled by the Go orchestrator"*), but the Go orchestrator sends **no** Slack
notifications today. Operators have no channel visibility into the go feature/task lifecycle — feature
starts, handoffs, completions, task blocks, and escalations are all invisible.

## Background / dependency
Depends on `go-orchestrator-autonomy`, which leaves `// TODO(slack): notify <event>` markers at every
lifecycle notification point (feature start/handoff/done, task start/in_review/blocked/completed,
missing-feature-branch at handoff, infra alert). This feature fills those seams with a real notifier.

## Goals
- **Bot-token threaded notifier in Go**, mirroring the TS `ThreadedSlackNotifier` (parity, not shared
  code): group each feature's events under **one Slack thread**, with task events nested as replies.
  (Incoming webhooks cannot thread — no message `ts` is returned and there is no `thread_ts` — so the
  bot-token Web API `chat.postMessage` / `chat.update` is required.)
- **Config:** `SLACK_BOT_TOKEN` (env) + `notifications.slack.channel_id` (already present in
  `workspace.yaml`). Graceful no-op when unconfigured. Reading config from the DB is a forward path.
- **Event set:**
  - Feature: started (`→in_implementation`), handoff opened, done (finalize).
  - Task: started (`→in_progress`), `→in_review`, **any** `→blocked` (escalations — reconciler/crash,
    spawn-DLQ, max-turns cap, review-incomplete cap, rebase_failed; and agent-reported —
    `tests_failed`, `missing_tool`, etc.), completed (merged → done).
  - Ops: missing-feature-branch repo at handoff; infra alert (redis enqueue failing across N cycles).
- **Thread store** mapping feature → `thread_ts` (TS uses Redis; Go may use Redis or a DB table).

## Non-goals
- Webhook-only mode (`SLACK_WEBHOOK_URL`) — cannot thread; bot token is required for grouping.
- Drift notifications — the drift daemon was dropped in `go-orchestrator-autonomy`.
- Re-using the TS notifier code — Go reimplements it.
- Changes to the broker, dispatcher, or executor.

## Open questions
1. Thread-store backend: Redis (as TS) vs a dedicated DB table.
2. Message format/content per event; whether task threads nest under the feature thread or sit as
   siblings.
3. Whether to keep a `SLACK_WEBHOOK_URL` fallback for environments without a bot token.
