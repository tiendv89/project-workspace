# Technical Design

> **Pending.** To be produced by `tech-lead` after the product spec is approved. The product spec
> already fixes the key direction (bot-token threaded notifier; webhooks can't thread; config from
> `SLACK_BOT_TOKEN` + `workspace.yaml notifications.slack.channel_id`; event set; thread-store).

## Feature
- Feature ID: `go-orchestrator-slack-notifications`
- Title: Go Orchestrator Slack Notifications (bot-token, threaded)

## Current State
The Go orchestrator sends no Slack notifications; TS delegates go-feature Slack to it. The sibling
`go-orchestrator-autonomy` feature leaves `// TODO(slack)` markers at each lifecycle notification
point for this feature to fill.

## Constraints
- Bot-token Web API required (incoming webhooks cannot thread).
- Reuse TS message conventions (parity, not shared code); no broker/dispatcher/executor changes.

## Options Considered
### Option A — Redis thread store (mirror TS)
- Pros: proven in TS; decoupled from the workflow DB.
- Cons: another Redis dependency to operate for a go-only concern.

### Option B — DB thread store
- Pros: reuses the workflow DB the orchestrator already owns; no extra infra.
- Cons: a new table; slightly more coupling.

## Chosen Design
_To be decided in tech-lead phase (see Open questions in product-spec)._

## Dependency Analysis
Depends on `go-orchestrator-autonomy` (the `// TODO(slack)` seams + the feature/task lifecycle events).

## Parallelization / Blocking Analysis
Blocked on `go-orchestrator-autonomy` landing the notification seams; the notifier itself is a single
self-contained workstream once those exist.
