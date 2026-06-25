# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: Shareable Trade Cards

## Problem

When users close a profitable trade on Voyager, there is no way to celebrate or share that moment. Competing platforms (e.g. Hyperliquid, dYdX) allow traders to generate a visual "trade card" — a branded image showing the asset, direction, P&L, and percentage return — that can be shared on social media. This drives organic word-of-mouth growth and strengthens brand identity.

`voyager-interface` already has access to the full trade record via `BaseExchangeClient.getTradeHistory` and `getOrderHistory`, so the underlying data is available. There is no UI component today that formats a completed trade into a shareable visual format.

## Goals

- After a trade is closed, show a "Share Trade" button in the trade history view within `voyager-interface`
- Clicking the button generates a branded trade card image (PNG) containing: asset pair, long/short direction, entry price, exit price, realised P&L (USD), percent return, and the Voyager logo
- Allow the user to download the PNG or copy a shareable link that opens a public-facing trade card page on `voyager-landing`
- The public trade card page on `voyager-landing` must be accessible without login and display the same trade details, with a CTA to sign up for Voyager
- Trade card data must be fetched from `voyager-backend` via a new public endpoint that returns anonymised trade details (no wallet address exposed — consistent with competition leaderboard privacy rules)

## Non-goals

- Automated social media posting (Twitter/X, Telegram) — copy link only for v1
- Trade cards for open/unrealised positions — closed trades only
- Video or animated trade cards
- Trade card customisation (colours, layouts, avatars) — fixed Voyager branding for v1
- Mobile (`voyager-mobile`) share flow — web only for v1
