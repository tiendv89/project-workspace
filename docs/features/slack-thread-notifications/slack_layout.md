# Slack Notification Layout — Final Design

Hybrid: Option B top-level (divider + bold labels) + Option C replies (compact inline).

Slack mrkdwn rules: `*bold*`, `_italic_`, Unicode `────` for dividers.
No Block Kit — all plain `text` field messages.

---

## Feature thread

### Top-level (created on `feature_start`, updated in place on every subsequent event)

```
*Slack Thread Notifications for Feature Runs*
────────────────────────────────────
🟢 in_implementation · 9 tasks
*Next action:* T1, T2, T7 ready (Wave 1, parallel)
```

```
*Slack Thread Notifications for Feature Runs*
────────────────────────────────────
🤝 in_handoff · 9 tasks
────────────────────────────────────
*Handoff:* https://github.com/tiendv89/project-workspace/pull/304
*PR:* https://github.com/tiendv89/project-workspace/pull/292
```

```
*Slack Thread Notifications for Feature Runs*
────────────────────────────────────
⚠️ blocked · 9 tasks
*Blocked:* WORKFLOW_LOCAL_PATH not set in .env
```

```
*Slack Thread Notifications for Feature Runs*
────────────────────────────────────
✅ done · 9 tasks
────────────────────────────────────
*PR:* https://github.com/tiendv89/project-workspace/pull/292
```

### Replies (audit trail, posted on each event after `feature_start`)

```
*handoff_submitted* · 🟢 in_implementation → 🤝 in_handoff
*Handoff:* https://github.com/tiendv89/project-workspace/pull/304
```

```
*feature_completed* · 🤝 in_handoff → ✅ done
*PR:* https://github.com/tiendv89/project-workspace/pull/292
```

```
*feature_summary_changed* · 🟢 in_implementation → ⚠️ blocked
*Blocked:* WORKFLOW_LOCAL_PATH not set in .env
```

---

## Task thread

### Top-level (created on `task_start`, updated in place on every subsequent event)

```
*T3 — Message types and formatters*
_Slack Thread Notifications for Feature Runs_
────────────────────────────────────
🟢 in_progress · workflow
*Branch:* feature/slack-thread-notifications-T3
*Workspace PR:* https://github.com/tiendv89/project-workspace/pull/292
*Execution:* agent@example.com
```

```
*T3 — Message types and formatters*
_Slack Thread Notifications for Feature Runs_
────────────────────────────────────
🔍 in_review · workflow
*Branch:* feature/slack-thread-notifications-T3
*Workspace PR:* https://github.com/tiendv89/project-workspace/pull/292
────────────────────────────────────
*PR:* https://github.com/tiendv89/agent-workflow/pull/208 (open)
*Execution:* agent@example.com
```

```
*T3 — Message types and formatters*
_Slack Thread Notifications for Feature Runs_
────────────────────────────────────
⚠️ blocked · workflow
*Branch:* feature/slack-thread-notifications-T3
*Workspace PR:* https://github.com/tiendv89/project-workspace/pull/292
*Blocked:* tests_failed
*Execution:* agent@example.com
```

```
*T3 — Message types and formatters*
_Slack Thread Notifications for Feature Runs_
────────────────────────────────────
✅ done · workflow
*Branch:* feature/slack-thread-notifications-T3
*Workspace PR:* https://github.com/tiendv89/project-workspace/pull/292
────────────────────────────────────
*PR:* https://github.com/tiendv89/agent-workflow/pull/208 (merged)
*Execution:* reviewer@example.com
```

### Replies (audit trail, posted on each event after `task_start`)

```
*task_status_changed* · 🟢 in_progress → 🔍 in_review
*PR:* https://github.com/tiendv89/agent-workflow/pull/208 (open)
```

```
*task_completed* · 🔍 in_review → ✅ done
*PR:* https://github.com/tiendv89/agent-workflow/pull/208 (merged)
*Execution:* reviewer@example.com
```

```
*task_status_changed* · 🟢 in_progress → ⚠️ blocked
*Blocked:* tests_failed
```

```
*task_pr_changed* · 🔍 in_review
*PR:* https://github.com/tiendv89/agent-workflow/pull/208 (open)
```

---

## Implementation notes

- `TaskContext` needs two new fields: `featureName: string` and `workspacePrUrl?: string | null`
- Second divider in task/feature top-level only appears when links are present (PR, Handoff)
- Reply status transition: `getStatusIcon(from) + ' ' + from + ' → ' + getStatusIcon(to) + ' ' + to`
- `· N tasks` on feature top-level only — never in replies
- `Execution:` line omitted when `lastUpdatedBy` is null
