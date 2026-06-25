# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: Referral Rewards Program

## Problem

Voyager has no user-facing surface for the referral system that already exists in the backend. `voyager-user-service` already implements `GenerateReferralCode`, `ValidateReferralCode`, and `ApplyReferralCode` endpoints (see `internal/app/api/route/v1/user/`), and the referral schema migration (`20260320000000_add_referral.up.sql`) has been applied. However, users have no way to discover, share, or track their referral code from `voyager-interface` (web) or `voyager-mobile`. There is also no reward logic — referrals are tracked but never monetised, so there is no incentive for users to refer others.

This leaves growth entirely dependent on paid channels, and the built referral infrastructure goes unused.

## Goals

- Expose a Referrals page in `voyager-interface` (web) and `voyager-mobile` where users can view their unique referral code, copy a shareable link, and see how many people they have referred
- Wire the registration flow to call `ApplyReferralCode` in `voyager-user-service` when a new user signs up with a referral link, attributing them to the referrer
- Implement a reward mechanism in `voyager-backend`: referrers earn a bonus credit for each referee who completes their first staking action within 30 days of sign-up
- Show pending and claimed reward balances on the Referrals page
- Notify referrers via `voyager-notification-service` when a referee completes their first stake and when a reward is credited to their account

## Non-goals

- Multi-tier (pyramid) referral chains — single-level attribution only
- Referral rewards for actions other than first stake (e.g. governance votes, deposits)
- Changes to the existing `ValidateReferralCode` or `ApplyReferralCode` API contracts in `voyager-user-service` — consume them as-is
- Fiat or token payout of rewards — platform credit only for v1
- Referral link expiry or per-code usage caps
