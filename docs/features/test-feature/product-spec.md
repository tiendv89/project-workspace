# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: Trading Competition Leaderboard

## Problem

`voyager-backend` contains a fully implemented competition domain — `LeaderboardRefreshHandler`, `RankParticipants` (supporting both absolute P&L and percent-return ranking modes), `GetLeaderboard`, and `GetLeaderboardEntriesByWallet` in `internal/domain/competition/` — but there is no UI in `voyager-interface` (web) or `voyager-mobile` that exposes it to users. Competitions exist in the backend but are invisible to participants, who have no way to check their current rank, see who they are competing against, or understand how rankings are calculated.

Without a visible leaderboard, the competition system provides no social or competitive incentive, which limits its effectiveness as a retention and engagement driver.

## Goals

- Add a Competitions page to `voyager-interface` (web) listing active and past competitions, each showing its name, duration, ranking mode (absolute P&L vs. percent return), prize structure, and number of participants
- Display the leaderboard for each competition sourced from `Service.GetLeaderboard` in `voyager-backend`, showing rank, anonymised wallet (hash already enforced by `TestGetLeaderboard_walletHashNotExposed`), P&L, and percent return for the top 100 participants
- Highlight the current user's own rank and stats via `GetLeaderboardEntriesByWallet`, even if they fall outside the top 100
- Refresh leaderboard data every 5 minutes on the client to reflect the periodic `LeaderboardRefreshHandler` updates from `voyager-backend`
- Send a push notification via `voyager-notification-service` when a user enters the top 10 of a competition they are participating in

## Non-goals

- Competition creation or administration — backend-only for v1, no admin UI
- Real-time leaderboard streaming — polling every 5 minutes is sufficient
- Prize distribution or on-chain reward settlement (separate feature)
- Mobile (`voyager-mobile`) leaderboard UI — web only for v1
- Exposing raw wallet addresses — hashed display only, consistent with existing backend privacy guarantees
