## Dependency Diagram

```
T1 (picker logic + tests) ──> T2 (picker UI + composer wiring)
T3 (message rendering: remarkChatTokens + FeatureMentionPill) ──> T4 (FeaturePopover + navigation)
```

T1 and T3 are independent and can proceed in parallel. T2 depends only on T1. T4 depends only on
T3 (it needs the pill's click entry point), though T4's data-fetching shell (reusing
`use-feature-detail.ts`) has no technical dependency and could be scaffolded early.

## Index

| ID | Title | Repo | Depends On | Actor |
|----|-------|------|------------|-------|
| T1 | Feature-mention trigger detection + filter/insert helpers | digital-factory-ui | | agent |
| T2 | FeatureMentionPicker UI + composer wiring (`//` trigger) | digital-factory-ui | T1 | agent |
| T3 | Render feature-mention tokens as inline pills in messages | digital-factory-ui | | agent |
| T4 | FeaturePopover (detail fetch + navigate) wired to pill click | digital-factory-ui | T3 | agent |

## T1 — Feature-mention trigger detection + filter/insert helpers

### Description
Add `src/components/agent-chat/feature-mention-picker.tsx` (logic only, no UI yet) implementing:
- `detectFeatureMention(value: string, cursor: number): { query: string; start: number } | null` —
  detects an in-progress `//` trigger span, mirroring `mention-picker.tsx`'s `detectMention`
  boundary logic (start-of-input or preceded by whitespace).
- `filterFeatures(features: Feature[], query: string): Feature[]` — case-insensitive substring
  match against `id` and `title`, same contract shape as `filterCommands` / `filterMembers`.
- `insertFeatureMention(value: string, start: number, cursorEnd: number, feature: Feature): { value: string; cursor: number }` —
  splices `//{feature.id}` into the input value, mirroring `insertMention`.
- A thin `useWorkspaceFeatures()` hook subscribing to the existing `query-keys.ts:features` cache
  entry (no refetch, no new endpoint) — reuses the same normalized `Feature` shape produced by
  `workspace-adapter.ts:adaptFeatureWithTasksToFeatures`.

Must not modify `mention-picker.tsx`, `slash-command-picker.tsx`, or any of their tests.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `detectFeatureMention` with whitespace/start-of-string boundary detection for `//`
- [ ] Implement `filterFeatures` (case-insensitive id/title substring match)
- [ ] Implement `insertFeatureMention`
- [ ] Implement `useWorkspaceFeatures()` thin wrapper over the existing `features` query key
- [ ] Unit tests in `feature-mention-picker-logic.test.ts` covering all three helpers (mirror the
      20-test shape of `mention-picker-logic.test.ts`)
- [ ] Confirm `slash-command-picker.test.ts` and `mention-picker-logic.test.ts` still pass unmodified

## T2 — FeatureMentionPicker UI + composer wiring (`//` trigger)

### Description
Build the `FeatureMentionPicker` component (modeled 1:1 on `MentionPicker`'s structure) rendering
a keyboard-navigable (↑/↓ + Enter, plus click) filtered list of feature rows (title + id + a small
stage/status badge). Wire it into the composer:
- In `agent-chat-panel.tsx:handleInputChange`, check `detectFeatureMention` **before** the existing
  single-`/` skill-picker check (so `//` doesn't get swallowed by the `/`-skill trigger), opening
  the feature picker and short-circuiting other trigger checks for that keystroke.
- Add `activePicker === 'feature'` alongside the existing `'skill' | 'member'` state values.
- Extend `handlePickerSelect` with a branch that calls `insertFeatureMention` on selection,
  mirroring the existing member-picker branch.
- No structural change needed to `PromptInputToolbar` / `PromptInput` — the new picker anchors the
  same way the existing two do.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Build `FeatureMentionPicker` component (list rendering, keyboard nav, click-select)
- [ ] Wire `detectFeatureMention` into `handleInputChange` ahead of the single-`/` check
- [ ] Add `activePicker === 'feature'` state and popover anchoring
- [ ] Extend `handlePickerSelect` to call `insertFeatureMention`
- [ ] Component tests: `//` opens picker, single `/` still opens skill picker only, `@` still
      opens member picker only (no trigger ambiguity), arrow-key nav, Enter/click selection
- [ ] Verify full existing composer test suite passes unmodified

## T3 — Render feature-mention tokens as inline pills in messages

### Description
Extend `message.tsx:remarkChatTokens` (and its `walk` helper) with a new token-recognition branch
for `//{feature-id}`, parallel to the existing `@handle` branch, producing a distinct AST node
type (`featureMention`). Add a new `<FeatureMentionPill>` inline component registered alongside
`MessageContent`, visually distinct from the `@handle` pill. This task only needs the token format
(`//{feature-id}`) — it can be implemented independently of T1/T2's picker UI.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add `featureMention` token recognition to `remarkChatTokens` / `walk`
- [ ] Implement `<FeatureMentionPill>` component (visually distinct from `@handle` pill)
- [ ] Register the new pill renderer alongside `MessageContent`
- [ ] Unit tests for token recognition (valid `//{id}` forms, edge cases, no false positives on
      unrelated `//` usage e.g. URLs)
- [ ] Confirm existing `@handle` token rendering and its tests are unaffected

## T4 — FeaturePopover (detail fetch + navigate) wired to pill click

### Description
Build `FeaturePopover`, opened when `<FeatureMentionPill>` (from T3) is clicked:
- Fetch feature detail by reusing the existing `use-feature-detail.ts` `queryFn` /
  `client.ts:getFeature` — no new fetch path.
- Render loading / loaded (title, id, stage/status badge, "Go to feature" button) / not-found
  states.
- "Go to feature" navigates using the same route resolution `feature-workbench.tsx` /
  `topbar.tsx:useBreadcrumbs` already use for a feature id, then closes the popover.
- Not-found state (404 or absence from the cached feature list): graceful empty state, "Go to
  feature" hidden or disabled.
- Read-only: no approve/reject/task-mutation affordances.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `FeaturePopover` with loading/loaded/not-found states
- [ ] Wire fetch to existing `use-feature-detail.ts` / `getFeature` (no new endpoint)
- [ ] Wire "Go to feature" navigation to the existing feature-workbench route resolution
- [ ] Wire `<FeatureMentionPill>` click handler to open `FeaturePopover`
- [ ] Unit tests: `feature-popover.test.ts` covering loading, loaded, not-found, and navigate-and-close behavior
