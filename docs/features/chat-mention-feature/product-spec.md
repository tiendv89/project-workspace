## content
# Product Specification

## Feature
- Feature ID: `chat-mention-feature`
- Title: Feature Mentions in Chat (`//` picker + inline popover)

## Problem
Today the chat composer (`src/components/agent-chat/prompt-input.tsx`) already supports two
trigger-driven pickers:
- `/` → `slash-command-picker.tsx` (skill commands, via `filterCommands`)
- `@` → `mention-picker.tsx` (thread members + `@agent`, via `detectMention` / `insertMention` /
  `filterMembers`)

There is no way to reference a **feature** inline in a conversation. Users currently have to
paste a feature ID/title as plain text (no affordance to browse/search features, no link back to
the feature, no quick-glance info). This is confirmed by the existing ad-hoc regex heuristic in
`board-panel.tsx` (`knownFeatureNames`, `extractMostRecentFeatureName`) that tries to *guess* a
mentioned feature from free text in `agent-general-chat` — a workaround, not a real authoring
affordance.

We want a first-class feature-mention experience:
1. Typing `//` in the composer opens a searchable popover listing workspace features (filterable
   by title/ID as the user keeps typing), modeled on the existing `/`-skill and `@`-member
   pickers in the same file.
2. Selecting a feature inserts an inline mention token into the message (analogous to the `@handle`
   pill rendering already implemented in `message.tsx` via `remarkChatTokens`).
3. Clicking a rendered feature-mention token in a sent message opens a popover showing quick info
   about that feature (title, current lifecycle stage/status) with a button to navigate to the
   feature (reusing the routing target already used by `feature-workbench.tsx` / `topbar.tsx`
   breadcrumbs and the workflow-backend `getFeature` client in
   `src/services/workflow-backend/client.ts`).

## Goals
- Typing `//` anywhere in the prompt input opens a `FeatureMentionPicker` popover, distinct from
  the existing `/` skill picker and `@` member picker triggers (no trigger collisions).
- The picker lists workspace features (id + title + stage/status badge) and narrows the list as
  the user types after `//`, using a `filterFeatures` helper analogous to `filterCommands` /
  `filterMembers`.
- Arrow-key navigation + Enter, and mouse click, both select a feature — consistent with the
  existing pickers' keyboard contract.
- Selecting a feature inserts a resolvable `//feature-id` mention token into the input (parallel
  to how `@handle` tokens are inserted via `insertMention`).
- Sent messages render feature-mention tokens as distinct inline pills (extending
  `remarkChatTokens` in `message.tsx`, alongside the existing `@handle` pill handling).
- Clicking a rendered feature-mention pill opens a `FeaturePopover` showing: feature title, feature
  ID, current lifecycle stage/status (sourced via `getFeature` / `use-feature-detail.ts`'s
  `queryFn`), and a "Go to feature" button that navigates to the feature's workbench route.
- The feature list backing the picker is fetched via the existing `features` query key
  (`src/constants/query-keys.ts`) / workspace features data path already used by the board
  (`workspace-adapter.ts` `adaptFeatureWithTasksToFeatures`, `feature-card.tsx`) — no new backend
  endpoint required for the list; the popover's detail fetch reuses `getFeature`.
- Works in every session kind that already hosts the composer (feature thread, Channel, Team Chat
  thread, DM) — same surfaces the `@`-mention picker (`m3-agent-chat-v4`) already supports.

## Non-goals
- No changes to the `/` skill-command picker or `@` member-mention picker behavior — this is an
  additive third trigger, not a rework of the existing two.
- No cross-workspace feature search — only features within the current workspace are listed.
- No push/external notifications when a feature is mentioned (in-app popover only, consistent with
  the existing in-app-only mention/unread rule from `m3-agent-chat-v4`).
- No editing of feature state from the popover — the popover is read-only info + navigate, it does
  not expose approve/reject or task actions (those remain in the feature workbench / board panel).
- No change to the `board-panel.tsx` auto-scoping heuristic (`extractMostRecentFeatureName`) —
  that remains a separate, existing mechanism; this feature adds an explicit authoring affordance
  instead.

## Acceptance Criteria
- Typing `//` in the composer opens the feature picker popover; typing additional characters after
  `//` filters the visible feature list by ID/title match.
- Arrow keys move the highlighted selection; Enter or a mouse click selects the highlighted/clicked
  feature and inserts its mention token into the input, closing the picker.
- Typing a single `/` (not `//`) still opens only the existing skill-command picker, and `@` still
  opens only the member picker — no trigger ambiguity or double-popover states.
- A sent message containing a feature-mention token renders it as a distinct inline pill (visually
  differentiated from `@handle` pills).
- Clicking a feature-mention pill opens a popover showing the feature's title, ID, and current
  stage/status, with a "Go to feature" button; clicking that button navigates to the feature's
  workbench page and closes the popover.
- If the mentioned feature no longer exists (deleted/renamed) the popover shows a graceful
  not-found state instead of erroring, and the "Go to feature" button is hidden or disabled.
- Existing `/` and `@` picker unit tests (`slash-command-picker`, `mention-picker-logic`) continue
  to pass unmodified; new tests cover `filterFeatures`, the `//` detection/insertion logic, and the
  `FeaturePopover` states (loaded, loading, not-found).
