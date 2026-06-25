# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: In-App Governance Voting

## Problem

Voyager users who hold governance tokens are currently required to leave the app and visit a third-party governance portal (e.g. Snapshot or Tally) to participate in protocol votes. This context-switching causes low voter participation — most users never complete the flow. Governance decisions that affect staking parameters, fee structures, and supported assets are therefore made by a small, technically sophisticated minority, undermining the decentralisation promise of the protocol.

The `voyager-backend` already indexes on-chain proposal data via `voyager-data-pipeline`, but there is no UI in `voyager-interface` or `voyager-mobile` to browse proposals or cast votes, and no integration with the wallet signing flow.

## Goals

- Add a Governance section to `voyager-interface` (web) and `voyager-mobile` listing all active, pending, and closed proposals
- Show each proposal's title, description, voting deadline, current vote tallies, and the user's current voting power
- Allow users to cast votes (For / Against / Abstain) directly in-app via wallet signature, without leaving Voyager
- Send a push notification via `voyager-notification-service` when a new proposal is published or when a vote the user participated in is about to close (48-hour reminder)
- Surface personalised voting power based on the user's staked balance, sourced from `voyager-user-service`

## Non-goals

- Proposal creation or on-chain submission (read + vote only for v1)
- Delegation of voting power to other addresses
- Support for governance systems outside the protocols already tracked by `voyager-data-pipeline`
- Discussion threads or comments on proposals
- Vote history export or analytics
