# Technical Design

## Feature
**Feature ID:** df-ui-debounce-fix
**Title:** Fix UI: relative timestamps, active status indicators, search debounce, and task title wrapping in digital-factory-ui

## 1. Current state

The `digital-factory-ui` is a single-page application that renders a task sidebar, a feature board, and search inputs for both task and feature list modes. The task sidebar currently displays each task with its ID, title, and status badge — but with three gaps:

- **No timestamps.** The sidebar renders task cards with title + status only. The API response includes `updated_at` per task, but it is not surfaced in the UI.
- **No active-state indicator.** The status badge renders static text/labels for the sidebar statuses (`blocked`, `in_progress`, `reviewing`, `in_review`, `ready`). There is no visual distinction between a task an agent is actively processing (`in_progress`, `reviewing`) and one that is idle.
- **No input debounce.** The search input fires an API request on every `onChange` event (every keystroke), with no debounce or throttle applied. This is true for both the task list search and the feature list search.
- **Task titles are shortened.** Task card titles are rendered in a shortened/ellipsis form in the sidebar and in task cards across feature/task modes, preventing users from reading the full text.

All changes are scoped to the `digital-factory-ui` repo (frontend only). No backend, API schema, or database changes are required.

## 2. Problem framing

Three independent UI fixes, all client-side:

| # | Problem | Root cause | Desired outcome |
|---|---------|------------|-----------------|
| 1 | No timestamps | `updated_at` field exists in API response but is unused in the sidebar component | Relative time displayed prominently on each task card |
| 2 | No active indicator | Status badge renders all statuses identically — no CSS distinction for active states | Animated spinner icon for `in_progress` and `reviewing` |
| 3 | No search debounce | `onChange` handler fires API request on every keystroke | 300ms debounce before API call triggers |
| 4 | Title shorthand | Task titles are truncated/ellipsized in sidebar cards and in task cards across feature/task modes | Full title displayed with wrapping up to 5 rows |

All four fixes are additive — they enhance existing components without removing or restructuring existing behavior. No feature flags are needed; each change can be shipped independently.

## 3. Options considered

### TD-A. Relative timestamp implementation

#### Option A1 — Use a date library (e.g., `date-fns`, `dayjs`)
- **Pros:** Well-tested, handles edge cases (locale, future dates, pluralization), provides `formatDistanceToNow` out of the box.
- **Cons:** Adds a dependency (~7–15 kB gzipped for `date-fns` tree-shaken). Overkill for a single relative-time display.

#### Option A2 — Custom `useRelativeTime` hook (vanilla JS)
- **Pros:** Zero dependencies. Full control over format strings. Lightweight (< 30 lines).
- **Cons:** Must handle edge cases manually (future dates, locale, pluralization). Slightly more code to maintain.

#### Selected for implementation: A2 (custom hook)
The formatting requirements are simple (seconds, minutes, hours, days). A custom hook is under 30 lines, avoids a dependency, and is trivially testable. If the app later needs richer date formatting across many components, `date-fns` can be introduced as a follow-up.

### TD-B. Spinner animation implementation

#### Option B1 — SVG spinner (inline or as a component)
- **Pros:** Sharp at any size, can animate rotation via CSS `transform`. Accessible (can add `<title>`).
- **Cons:** Requires an SVG asset or inline markup. Slightly more DOM nodes than pure CSS.

#### Option B2 — Pure CSS `@keyframes` spinner on a `<span>` or pseudo-element
- **Pros:** Zero DOM overhead beyond a single element. No external assets. Trivially styleable via CSS custom properties.
- **Cons:** Less crisp than SVG at extreme sizes. No built-in accessibility label (can be added via `aria-label`).

#### Selected for implementation: B1 (SVG spinner)
While pure CSS spinners work, SVG is the standard for loading indicators in modern UIs — it renders sharply at any size, supports `prefers-reduced-motion`, and can include an accessible `<title>`. The SVG markup is a single `<svg>` element (~10 lines) that can be inlined in the StatusBadge component. Animation is still handled by CSS (`animation: spin 1s linear infinite` on the SVG root).

### TD-C. Debounce implementation

#### Option C1 — `lodash.debounce` / `lodash`
- **Pros:** Battle-tested, handles edge cases (leading/trailing, `cancel`, `flush`). Familiar API.
- **Cons:** Adds a dependency. `lodash.debounce` is ~1 kB, but full `lodash` is much larger.

#### Option C2 — Custom `useDebounce` hook (React)
- **Pros:** Zero dependencies. React-idiomatic (returns a debounced value that triggers re-render). Handles cleanup on unmount automatically.
- **Cons:** Must implement manually (~10 lines). Need to ensure `useEffect` cleanup cancels pending timeouts.

#### Selected for implementation: C2 (custom hook)
A `useDebounce` hook is the React-standard pattern for this use case. It is under 10 lines, avoids a dependency, and integrates naturally with the existing `useEffect`-driven search flow. The hook wraps `setTimeout`/`clearTimeout` — no complex edge cases for a simple input debounce.

### TD-D. Task title rendering

#### Option D1 — Full text with no clamp (auto height)
- **Pros:** Always shows the entire title.
- **Cons:** Can produce very tall cards, causing layout shifts and reduced scannability in the sidebar.

#### Option D2 — Multi-line wrap with a 5-row clamp
- **Pros:** Shows full text in most cases, preserves sidebar density, avoids extreme layout shifts.
- **Cons:** Very long titles are still truncated after 5 rows (needs ellipsis).

#### Selected for implementation: D2 (5-row clamp)
A 5-row clamp balances readability and layout stability. It removes the current shorthand/ellipsis while preventing pathological titles from expanding the sidebar excessively.

## 4. Chosen design

**Selected options:** A2 (relative time hook), B1 (SVG spinner), C2 (debounce hook), D2 (5-row clamp).

### 4.1 `useRelativeTime` hook (Issue 1)

Implements **Option A2** (custom hook).

```typescript
function useRelativeTime(isoTimestamp: string | null): string {
  const [display, setDisplay] = useState('');

  useEffect(() => {
    function tick() {
      if (!isoTimestamp) { setDisplay(''); return; }
      const diff = Date.now() - new Date(isoTimestamp).getTime();
      const seconds = Math.floor(diff / 1000);

      if (seconds < 0)  setDisplay('just now');
      else if (seconds < 60) setDisplay(`${seconds}s ago`);
      else if (seconds < 3600) setDisplay(`${Math.floor(seconds / 60)}m ago`);
      else if (seconds < 86400) setDisplay(`${Math.floor(seconds / 3600)}h ago`);
      else setDisplay(`${Math.floor(seconds / 86400)}d ago`);
    }
    tick();
    const interval = setInterval(tick, 30_000); // refresh every 30s
    return () => clearInterval(interval);
  }, [isoTimestamp]);

  // Recalculate on window focus
  useEffect(() => {
    window.addEventListener('focus', tick);
    return () => window.removeEventListener('focus', tick);
  }, [isoTimestamp]);

  return display;
}
```

- Hook takes `updated_at` (ISO 8601 string or `null`), returns a display string.
- Refreshes every 30 seconds while the tab is open.
- Recalculates on `window` focus event (tab switch / browser refocus).
- Returns empty string if `updated_at` is `null` (caller decides whether to render or fallback to "N/A").

**Placement:** Task sidebar card — appended below or beside the task title/status line. Styled with a muted-but-visible color (e.g., `text-gray-500`) and slightly smaller font size, or a distinct accent if "prominence" requires it per the spec. Exact styling deferred to implementation; the spec requires it to be "visually prominent".

### 4.2 Spinner icon for `in_progress` + `reviewing` (Issue 2)

Implements **Option B1** (SVG spinner).

**SVG spinner:**

```html
<svg class="spinner" width="14" height="14" viewBox="0 0 14 14" aria-label="Processing">
  <title>Processing</title>
  <circle cx="7" cy="7" r="5" fill="none" stroke="currentColor"
          stroke-width="2" stroke-dasharray="20 10" stroke-linecap="round"/>
</svg>
```

**CSS animation:**

```css
.spinner {
  animation: spin 1s linear infinite;
}
@keyframes spin {
  to { transform: rotate(360deg); }
}
@media (prefers-reduced-motion: reduce) {
  .spinner { animation: none; }
}
```

**Placement:** Inline with the status badge — the spinner replaces or sits beside the status label for `in_progress` and `reviewing` tasks. The spinner uses the status badge's accent color for visual consistency. The `prefers-reduced-motion` media query disables the animation for accessibility.

### 4.3 `useDebounce` hook (Issue 3)

Implements **Option C2** (custom hook).

```typescript
function useDebounce<T>(value: T, delay: number): T {
  const [debouncedValue, setDebouncedValue] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedValue(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);

  return debouncedValue;
}
```

**Usage in search component:**

```typescript
const [searchInput, setSearchInput] = useState('');
const debouncedSearch = useDebounce(searchInput, 300);

useEffect(() => {
  if (debouncedSearch !== undefined) {
    fetchTasks({ search: debouncedSearch });
  }
}, [debouncedSearch]);
```

- The raw `searchInput` drives the `<input>` value (so the user sees their typing in real time).
- The debounced value drives the API call (so the API only fires after 300ms of inactivity).
- Cleanup on unmount cancels any pending timeout — no stale setState warnings.
- Applied identically to both task list search and feature list search.

### 4.4 Task title wrapping (Issue 4)

Implements **Option D2** (5-row clamp).

Apply a multi-line clamp to task titles in the sidebar card and task cards across feature/task modes:

```css
.task-title {
  display: -webkit-box;
  -webkit-line-clamp: 5;
  -webkit-box-orient: vertical;
  overflow: hidden;
  word-break: break-word;
}
```

- Titles wrap naturally across lines up to 5 rows.
- Very long titles are clamped at row 5 (ellipsis if the browser applies it).
- This removes the current shorthand while keeping the layout stable across sidebar and feature/task cards.

### 4.5 Component impact summary

| Component | Change | New file |
|-----------|--------|----------|
| `TaskSidebar` / `TaskCard` | Render relative timestamp below status; allow title to wrap up to 5 rows | — |
| `Feature` / `Task` cards | Allow title to wrap up to 5 rows | — |
| `StatusBadge` | Render SVG spinner for `in_progress` + `reviewing` | — |
| `SearchInput` (task mode) | Wire `useDebounce` into the search effect | — |
| `SearchInput` (feature mode) | Wire `useDebounce` into the search effect | — |
| — | `src/hooks/useRelativeTime.ts` | ✓ new |
| — | `src/hooks/useDebounce.ts` | ✓ new |

## 5. Dependency analysis

### Internal dependencies

- The two hooks (`useRelativeTime`, `useDebounce`) have zero internal dependencies — they are pure client-side utilities consuming only React and browser APIs.
- The spinner SVG is a self-contained inline element — no icon library or asset pipeline dependency.

### External dependencies

- None. No new npm packages required.

### Configuration dependencies

- None. No environment variables, feature flags, or API changes needed.
- The `updated_at` field already exists in the API response. If the field format changes, the `useRelativeTime` hook would need a corresponding parser update (unlikely — ISO 8601 is stable).

### Release dependencies

- None. Each fix ships independently; no coordination with backend or other repos required.

### Unresolved dependencies

- None.

## 6. Parallelization / blocking analysis

```
T1: Relative timestamps — TaskSidebar + useRelativeTime hook
  └── Can begin now — no blockers

T2: Animated spinner — StatusBadge + SVG spinner
  └── Can begin now — no blockers

T3: Search debounce — SearchInput + useDebounce hook
  └── Can begin now — no blockers

T4: Task title wrap — TaskCard line clamp (5 rows)
  └── Can begin now — no blockers

T1, T2, T3, and T4 run in parallel
```

All four tasks touch **different files** and have no logical dependencies on each other. They can be implemented, tested, and reviewed independently. Any task can ship without waiting for the others.

## 7. Repository impact

| Repo | Impact |
|------|--------|
| `digital-factory-ui` | Only repo affected. Three independent component updates + two new hook files. |

Task repo values must use `digital-factory-ui` (matching `workspace.yaml -> repos[].id`).

## 8. Validation and release impact

### Testing expectations

| Task | Test type | What to verify |
|------|-----------|----------------|
| T1 | Unit | `useRelativeTime` returns correct string for 0s, 30s, 5m, 2h, 3d inputs; returns empty for `null`; handles future dates gracefully |
| T1 | Integration | Task sidebar renders timestamp for every task; refreshes on window focus |
| T2 | Unit | StatusBadge renders SVG spinner for `in_progress` and `reviewing`; renders static label for all other statuses |
| T2 | Accessibility | Spinner respects `prefers-reduced-motion: reduce` |
| T3 | Unit | `useDebounce` only updates value after `delay` ms of inactivity |
| T3 | Integration | Rapid typing in search input triggers exactly one API call after 300ms pause |
| T4 | Visual | Task titles wrap across multiple lines up to 5 rows; longer titles clamp at row 5 |

### Migration / config impact

- No migration steps. No config changes. No database schema changes.
- Existing components are enhanced in place — no prop API changes, no breaking changes.

### Rollout concerns

- Single PR deploy. Changes are purely additive — rolling back any individual fix is a straightforward revert.
- Low risk: all three changes are visual/client-side only, with no backend coupling.

### Backward compatibility

- Fully backward compatible. Existing statuses render exactly as before (only `in_progress` and `reviewing` gain the spinner).
- Search behavior is a strict improvement — the API receives fewer requests, but the response handling is unchanged.
- The timestamp is a new UI element that does not affect existing layout or interaction.

### Deployment / handoff implications

- Standard frontend deploy pipeline. No database migrations, no API version bumps.
- Monitor: after deploy, verify that (a) timestamps appear on all task cards, (b) spinners animate for active tasks, and (c) search API call volume drops to one per typing burst.
