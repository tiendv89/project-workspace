# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: User Notification Preferences

## Problem

Users currently receive all notifications from the Voyager platform without any ability to customize which alerts they want. This leads to notification fatigue — users are bombarded with irrelevant updates (e.g. minor price movements, routine staking rewards) and end up ignoring or disabling all notifications entirely, causing them to miss critical events like liquidation warnings or large portfolio swings.

There is no UI surface in the Voyager interface or mobile app where users can opt in or out of specific notification categories. The `voyager-notification-service` sends all event types to all subscribed users indiscriminately.

## Goals

- Allow users to configure their notification preferences per category (e.g. staking rewards, price alerts, liquidation warnings, governance votes)
- Persist preferences in `voyager-user-service` against the user's profile
- Respect preferences in `voyager-notification-service` before dispatching any notification
- Expose a preferences UI in `voyager-interface` (web) and `voyager-mobile` (iOS/Android)
- Default new users to receiving only high-priority notifications (liquidation warnings, security alerts)

## Non-goals

- Per-asset or per-pool granularity within a category (v2 scope)
- Push notification channel selection (email vs. push vs. SMS) — channel management is handled by a separate feature
- Retroactive suppression of already-delivered notifications
- Admin override of user preferences
