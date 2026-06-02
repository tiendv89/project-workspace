# Task Breakdown — df-ui-debounce-fix

Feature status: `in_tdd`. Stage: `technical_design` (draft). Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Relative timestamps in task sidebar | — |
| T2 | 1 | Spinner for active statuses | — |
| T3 | 1 | Debounced search input | — |
| T4 | 1 | Task title wrapping (5 rows) | — |

## T1 — Relative timestamps in task sidebar

### Description
Add a client-side relative timestamp to each task card in the sidebar using `updated_at` compared to browser time. The timestamp must be visually prominent and recalculate on window focus or data refresh. Implement a small `useRelativeTime` hook with no external dependencies.

### Required skills
- <!-- none -->

### Subtasks
- [ ] Implement `useRelativeTime` hook (seconds/minutes/hours/days) with fallback for missing `updated_at`
- [ ] Render relative time in task sidebar card layout with prominent styling
- [ ] Recalculate on window focus and at a light interval (e.g., 30s)
- [ ] Verify timestamps render for all tasks without breaking layout

---

## T2 — Spinner for active statuses

### Description
Add a visible, animated spinner icon for tasks in `in_progress` and `reviewing` statuses to indicate active processing. Use an inline SVG + CSS animation (no new dependencies) and respect `prefers-reduced-motion`.

### Required skills
- <!-- none -->

### Subtasks
- [ ] Add SVG spinner element in the status badge component
- [ ] Apply CSS `@keyframes` spin animation and `prefers-reduced-motion` handling
- [ ] Render spinner only for `in_progress` and `reviewing` statuses
- [ ] Ensure spinner is visually prominent but not disruptive

---

## T3 — Debounced search input

### Description
Add a 300ms debounce to search input in both task list and feature list modes to prevent API calls on every keystroke. Implement a small `useDebounce` hook and wire it into the existing search effect.

### Required skills
- <!-- none -->

### Subtasks
- [ ] Implement `useDebounce` hook (React)
- [ ] Use debounced value to trigger task search API calls
- [ ] Use debounced value to trigger feature search API calls
- [ ] Verify typing triggers a single API request after 300ms pause

---

## T4 — Task title wrapping (5 rows)

### Description
Display full task titles in the sidebar and in task cards across feature/task modes without shorthand by allowing line wrapping up to 5 rows. Apply a CSS line clamp to prevent extremely long titles from expanding the card beyond 5 lines.

### Required skills
- <!-- none -->

### Subtasks
- [ ] Update task card title styles in sidebar + feature/task cards to allow multi-line wrapping
- [ ] Apply a 5-line clamp (`-webkit-line-clamp: 5`) with overflow hidden
- [ ] Verify long titles are readable and clamped at row 5
- [ ] Confirm layout remains stable in the sidebar and feature/task cards
