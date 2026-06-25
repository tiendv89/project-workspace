# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: Staking Portfolio Dashboard

## Problem

Users who stake assets across multiple pools on the Voyager platform have no single view to monitor their combined staking positions. They must navigate between individual pool pages to check balances, pending rewards, and APY changes. This fragmented experience makes it difficult to manage a diversified staking strategy and increases the risk that users miss time-sensitive opportunities (e.g. a pool's APY dropping significantly) or fail to claim rewards before expiry.

The `voyager-data-pipeline` already aggregates on-chain staking data, but neither `voyager-interface` (web) nor `voyager-mobile` exposes a unified portfolio summary view. The data exists — the presentation layer is missing.

## Goals

- Provide a unified Staking Portfolio Dashboard in `voyager-interface` (web) showing all active staking positions, total staked value, aggregate pending rewards, and per-pool APY
- Mirror the dashboard as a summary screen in `voyager-mobile`
- Source data from `voyager-backend` via a new `/portfolio/staking` endpoint backed by `voyager-data-pipeline`
- Allow users to claim all pending rewards in a single transaction from the dashboard
- Show 7-day APY trend sparklines per pool so users can spot declining yields quickly

## Non-goals

- Cross-chain portfolio aggregation beyond networks already supported by `voyager-data-pipeline`
- Tax reporting or cost-basis tracking
- Automated restaking / compounding logic (separate feature)
- Historical performance charts beyond the 7-day sparkline
- Support for non-staking positions (liquidity pools, lending) in this view
