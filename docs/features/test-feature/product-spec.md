# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: Portfolio P&L Breakdown & Transfer History

## Problem

The existing `PortfolioPage` in `voyager-interface` renders a `PortfolioTab` that surfaces aggregate `totalPnL` and `volume` figures, but provides no breakdown of how those numbers are composed. Users cannot tell which positions drove gains or losses, how fees affected their P&L, or how their portfolio value has changed over time. The `PortfolioChart` interface and `getTransferHistory` method already exist in `src/client/base-client.ts` but are unused in the UI — meaning the underlying data is available but never shown.

Without this breakdown, users cannot make informed decisions about rebalancing or closing positions, and have no audit trail of fund movements in or out of the platform.

## Goals

- Extend `PortfolioTab` in `voyager-interface` to display a per-position P&L breakdown table showing: asset, entry price, current price, unrealised P&L (USD and %), realised P&L, and fees paid
- Add a Portfolio Chart section to `PortfolioPage` using the existing `PortfolioChart` interface from `base-client.ts` showing total portfolio value over selectable time ranges (24h, 7d, 30d, 90d)
- Add a Transfer History tab to `PortfolioPage` powered by `BaseExchangeClient.getTransferHistory`, showing deposits, withdrawals, and internal transfers with timestamps, amounts, and status
- All three additions must work within the existing `usePortfolio` data-fetching hook — extend it rather than adding a parallel fetch layer
- Make the new sections responsive and consistent with the existing `PortfolioPage` layout

## Non-goals

- Tax lot tracking or cost-basis calculation methods (FIFO/LIFO)
- CSV export of transfer history or P&L (separate feature)
- Changes to `base-client.ts` API contracts — consume existing methods only
- Portfolio comparison against benchmarks (e.g. BTC, ETH index)
- Mobile (`voyager-mobile`) — web only for v1
