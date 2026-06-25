# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: Subscription Plan Management

## Problem

`voyager-user-service` already manages subscription-linked credits via `AddCreditsForSubscriptionGrant` and `CapCreditsForSubscriptionExpiry` in `CreditService`, and the `UserCreditRepository` tracks credit balances per user. However, users have no visibility into what subscription plan they are on, what benefits it includes, how many credits they have remaining, or when their plan renews or expires.

Users currently receive credits silently in the background with no UI to understand the value they are getting, compare plans, or upgrade. This creates a poor monetisation experience and high churn risk — users don't perceive value they can't see.

## Goals

- Add a Subscription page to `voyager-interface` (web) and `voyager-mobile` showing the user's current plan tier, credit balance (sourced from `CreditService` via `voyager-user-service`), renewal date, and a breakdown of what their plan includes (e.g. AI agent queries per month, alert slots, API rate limits)
- Display available plan tiers with a feature comparison table so users can evaluate upgrading
- Allow users to upgrade or downgrade their plan from within the app, triggering the appropriate `AdjustUserCreditsWithHistory` and subscription grant/expiry flows in `voyager-user-service`
- Show a low-credit warning banner in `voyager-interface` and `voyager-mobile` when the user's credit balance falls below 20% of their plan allowance
- Notify users via `voyager-notification-service` 7 days before their subscription expires and when a plan change is confirmed

## Non-goals

- Payment processing or billing UI — Stripe or equivalent is handled out-of-band; this feature covers only the in-app plan display and credit tracking
- Free-tier sign-up flow changes
- Admin plan management console (separate feature)
- Annual vs. monthly billing toggle — monthly only for v1
- Credit gifting or transfer between users
