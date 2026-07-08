## content
# Technical Design

## Feature
- Feature ID: `chat-mention-feature`
- Title: Feature Mentions in Chat (`//` picker + inline popover)

## Current State
The chat composer lives in `digital-factory-ui`, `src/components/agent-chat/`. Two trigger-driven
pickers already exist side by side in `prompt-input.tsx`, wired through
`agent-chat-panel.tsx:handleInputChange` / `handlePickerSelect`:

- **`/` skill picker** — `slash-command-picker.tsx`. Pure helper `filterCommands` (lines 21–25)
  narrows the visible skill list as the user types after `/`.
- **`@` member picker** — `mention-picker.tsx`. Helper trio: `detectMention` (104–110, finds the
  active `@`-trigger span in the input value + cursor position), `insertMention` (113–118, splices
  the resolved token into the input value), `filterMembers` (14–18, narrows by query). Rendered by
  `MentionPicker` (20–101). This is the pattern proven out in `m3-agent-chat-v4/T7`
  (`mention-picker-logic.test.ts`: 20 unit tests for exactly this trio).

Rendered messages go through `message.tsx:remarkChatTokens` (44–101), a remark plugin that walks
the markdown AST (`walk`, 49–98) and rewrites recognized tokens (currently `@handle`) into styled
inline elements consumed by `MessageContent` (157–165) inside `MessageThread`
(`message-thread.tsx`, `ToolCallGroup` / `renderedCards`).

Feature list data already flows into the UI without a new endpoint:
- `workspace-adapter.ts:adaptFeatureWithTasksToFeatures` (48–59) and
  `adaptTaskSummariesToFeatures` (91–113) — called from `kanban-board.context.tsx` — normalize
  backend feature+task payloads into the UI's `Feature` shape (via
  `normalizeFeatureLifecycleStatus`), used today by `feature-card.tsx:FeatureCard` and the board.
- `src/constants/query-keys.ts` — `features` (34) and `feature` (36) query keys already exist.
- `src/services/workflow-backend/client.ts:getFeature` (95–97) — already called from
  `use-feature-detail.ts:queryFn` (21), which backs `feature-document-panel.tsx`. This is the exact
  fetch the mention popover's detail view needs (title, stage/status).
- Navigation target: `feature-workbench.tsx` and `topbar.tsx:useBreadcrumbs` already establish the
  canonical feature route; `board-panel.tsx`'s `knownFeatureNames` shows the existing (separate,
  regex-based) auto-scoping mechanism we are explicitly not touching.

There is currently no `//`-triggered picker and no feature-mention token type in
`remarkChatTokens`.

## Constraints
- Must not regress or change behavior of the existing `/` skill picker or `@` member picker —
  additive third trigger only (product spec non-goal).
- Trigger detection must disambiguate `/` (skill picker) from `//` (feature picker) reliably —
  a naive "starts with `/`" check will misfire on `//`. Detection must special-case the two-char
  prefix before falling through to single-`/` handling.
- No new backend endpoint for the list — must reuse the existing feature/task adapter data path
  already powering the board `features` query key.
- Detail popover must reuse `getFeature` (via `use-feature-detail.ts`), not invent a second fetch
  path.
- In-app only — no external notification plumbing (product spec non-goal), consistent with the
  existing mention/unread rules from `m3-agent-chat-v4`.
- Read-only popover — no write/approve/reject affordances (product spec non-goal).

## Options Considered
### Option A — Extend `mention-picker.tsx` to also handle `//` (single generalized picker)
- Pros: one file, shared keyboard-nav plumbing.
- Cons: conflates two unrelated entity types (thread members vs. features) inside one component's
  internal state/branching; higher risk of regressing the well-tested `@`-member flow
  (`mention-picker-logic.test.ts`'s 20 existing tests) since `detectMention`/`insertMention`/
  `filterMembers` would need trigger-aware branches threaded through the same functions.

### Option B — New sibling `FeatureMentionPicker` + `feature-mention-picker.tsx` (mirrors existing pattern), wired alongside the other two in `prompt-input.tsx`/`agent-chat-panel.tsx`
- Pros: matches the codebase's established pattern exactly (one file per trigger type: skills,
  members, now features); zero risk to existing `/` and `@` logic; isolated, independently
  testable helpers (`detectFeatureMention`, `insertFeatureMention`, `filterFeatures`); trigger
  disambiguation is centralized in one dispatcher in `handleInputChange` rather than spread across
  a shared component's internals.
- Cons: slightly more boilerplate (new file, new picker component) versus reusing one.

**Chosen: Option B.** It follows the codebase's own precedent (three sibling pickers, not one
overloaded picker), keeps blast radius on existing tested code at zero, and keeps each helper unit
independently testable exactly like the `@`-picker's proven test suite.

## Chosen Design

### 1. Trigger detection (`feature-mention-picker.tsx`, new file, `digital-factory-ui`)
- `detectFeatureMention(value: string, cursor: number): { query: string; start: number } | null` —
  scans backward from the cursor for a `//` prefix that is either at the start of input or
  preceded by whitespace (mirrors `detectMention`'s boundary logic), returning the in-progress
  query text after `//`.
- Dispatcher change in `agent-chat-panel.tsx:handleInputChange` (700–707): check
  `detectFeatureMention` **before** the existing single-`/` skill-picker check, since `//` is a
  more specific prefix match than `/`. If it matches, open `FeatureMentionPicker` and short-circuit
  — do not also evaluate the skill-picker or member-picker triggers for the same keystroke.
- `filterFeatures(features: Feature[], query: string): Feature[]` — case-insensitive substring
  match against `id` and `title`, same contract shape as `filterCommands` / `filterMembers`.
- `insertFeatureMention(value: string, start: number, cursorEnd: number, feature: Feature): { value: string; cursor: number }` —
  splices `//{feature.id}` into the input, mirroring `insertMention`.
- `FeatureMentionPicker` component (new, modeled 1:1 on `MentionPicker`'s 20–101 structure):
  renders a filtered, keyboard-navigable list (↑/↓ + Enter, plus click) of feature rows (title +
  id + a small stage/status badge sourced from the same normalized `Feature` shape
  `adaptFeatureWithTasksToFeatures` already produces).
- Feature list source: read from the same query-cache entry the board uses
  (`query-keys.ts:features`), via a small `useWorkspaceFeatures()` hook (new, thin wrapper) so the
  picker doesn't refetch — it subscribes to the existing cached/query-key data.

### 2. Token insertion + wiring (`agent-chat-panel.tsx`, `prompt-input.tsx`)
- `handlePickerSelect` (709–712) gains a branch for the feature picker's selection callback,
  calling `insertFeatureMention` analogous to the existing member-picker branch.
- `PromptInputToolbar` / `PromptInput` (147–159, 277–283) require no structural change — the new
  picker renders as a popover anchored the same way the existing two are (same overlay/positioning
  utility), just gated on a new `activePicker === 'feature'` state value alongside the existing
  `'skill' | 'member'` states.

### 3. Rendering sent mentions (`message.tsx`)
- Extend `remarkChatTokens` (44–101) and its `walk` helper (49–98) with a new token-recognition
  branch for `//{feature-id}` (parallel to the existing `@handle` branch), producing a distinct
  AST node type (e.g. `featureMention`) consumed by a new small renderer registered next to
  `MessageContent` (157–165) — a `<FeatureMentionPill>` inline component, visually distinct from
  the `@handle` pill (per acceptance criteria).

### 4. Click → popover (`FeaturePopover`, new component)
- `<FeatureMentionPill>` opens `FeaturePopover` on click, which:
  - Calls `use-feature-detail.ts`'s existing `queryFn` (21) / `getFeature` (95–97 in
    `client.ts`) with the mentioned `feature.id`.
  - Renders loading / loaded (title, id, stage/status badge, "Go to feature" button) / not-found
    states.
  - "Go to feature" button navigates using the same route target `feature-workbench.tsx` /
    `topbar.tsx:useBreadcrumbs` already resolve for a feature id, then closes the popover.
  - Not-found state (404 from `getFeature`, or client-side absence in the cached feature list):
    render a graceful empty state, hide/disable the "Go to feature" button — per acceptance
    criteria.

### 5. Testing
- New unit tests mirroring `mention-picker-logic.test.ts`'s shape:
  `feature-mention-picker-logic.test.ts` for `detectFeatureMention` / `insertFeatureMention` /
  `filterFeatures`.
- `feature-popover.test.ts` for loading/loaded/not-found rendering and the navigate action.
- Regression check: existing `slash-command-picker.test.ts` and `mention-picker-logic.test.ts`
  must continue to pass unmodified — no shared code path was touched by Option B.

## Figma
No Figma URLs are present in the approved product spec for this feature — no `## Figma` section
is required. If a design file is provided later for the picker/popover visuals, it must be added
here and propagated into the relevant frontend tasks' `### Figma` subsections per the Figma link
propagation rule before those tasks are marked `ready`.

## Dependency Analysis
- Single repo: `digital-factory-ui`. No backend or `workflow-backend` changes required — the list
  path reuses the existing `features` query key / adapter, and the detail path reuses the existing
  `getFeature` client call, both already implemented and deployed.
- No dependency on `user-service`, `workflow-backend`, or any other indexed repo for this feature's
  scope.
- Internal ordering within `digital-factory-ui`:
  1. Trigger-detection + filter helpers (`feature-mention-picker.tsx` logic) — no UI dependency,
     can be built and unit-tested first.
  2. `FeatureMentionPicker` component + wiring into `agent-chat-panel.tsx` / `prompt-input.tsx` —
     depends on (1).
  3. `remarkChatTokens` extension + `<FeatureMentionPill>` rendering in `message.tsx` — independent
     of (1)/(2); can proceed in parallel since it only needs the token *format* (`//{feature-id}`)
     agreed upon in (1), not the picker implementation itself.
  4. `FeaturePopover` component — depends on (3) existing (the pill is what triggers the popover),
     but its data-fetching logic (reusing `use-feature-detail.ts`) has no dependency on (1)/(2)/(3)
     and could be scaffolded early.

## Parallelization / Blocking Analysis
- **Parallelizable:** (1) picker logic/helpers, (3) token rendering in `message.tsx`, and the
  data-fetching shell of (4) `FeaturePopover` can all start immediately and in parallel — none
  blocks another at the code level, only at the final wiring/integration step.
- **Blocking:** final wiring of the picker into `agent-chat-panel.tsx`'s `handleInputChange` /
  `handlePickerSelect` (step 2) depends on (1) being merged first (shared file). Similarly,
  `<FeatureMentionPill>` wiring the click handler to open `FeaturePopover` depends on both (3) and
  (4) existing.
- All work is confined to `digital-factory-ui` — no cross-repo blocking, no task needs to wait on
  another repo's PR.
- Suggested task split (to be finalized at task-breakdown stage): T1 picker logic + tests, T2
  picker UI + composer wiring (depends on T1), T3 message rendering (`remarkChatTokens` +
  `FeatureMentionPill`) — independent of T1/T2, T4 `FeaturePopover` + navigation (depends on T3 for
  the click entry point, but its data layer can start immediately).
