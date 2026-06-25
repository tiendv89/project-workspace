# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: Self-Serve Price & Portfolio Alert Management

## Problem

The `faro-alert-engine` already supports typed alert conditions (including threshold-cross-below/above evaluation via `CreateAlertFromConditionType` and `MapConditionType`) and can list a user's active alerts via `ListAlerts` / `ListByUserID`. However, users have no way to create, edit, or delete their own alerts from `voyager-interface` (web) or `voyager-mobile`. Alert configuration today requires direct API access or admin intervention, meaning only technical users benefit from the alert system.

As a result, non-technical users — the majority of the platform's audience — never receive proactive notifications about price movements or portfolio threshold breaches that would help them act before losses occur.

## Goals

- Add an Alerts management page to `voyager-interface` (web) and `voyager-mobile` where users can:
  - Create new alerts by selecting an asset, condition type (price above / price below / portfolio value change %), and threshold value
  - View all their active and triggered alerts, including last-fired time and current status
  - Edit alert thresholds and notification frequency on existing alerts
  - Delete alerts they no longer need
- Wire the UI to `faro-alert-engine`'s existing `CreateAlertFromConditionType`, `ListAlerts`, and alert update/delete endpoints
- Default new alerts to a "once per day" notification frequency to prevent alert fatigue
- Show a badge count of unacknowledged triggered alerts in the main navigation of `voyager-interface` and `voyager-mobile`

## Non-goals

- Creating new alert condition types beyond what `faro-alert-engine` already supports via `MapConditionType`
- Alert sharing or team-level alerts
- Webhook or email delivery channels — push notification via `voyager-notification-service` only for v1
- Bulk alert import/export
- Alert history or audit log beyond the last-fired timestamp already stored by `faro-alert-engine`
