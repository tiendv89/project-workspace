# Tasks — Workflow Dashboard Web

Feature status reference: `in_tdd`; stage status: `tasks/draft`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | React/Vite feature architecture and provider scaffold | [] |
| T2 | 2 | Workspace domain services and import provider | [T1] |
| T3 | 3 | Workspace list page compound components | [T2] |
| T4 | 3 | Board shell, workspace switcher, and Add workspace modal | [T2] |
| T5 | 3 | Kanban and task detail compound components | [T1] |
| T6 | 4 | Route integration, fallback screens, and toast wiring | [T3, T4, T5] |
| T7 | 5 | End-to-end QA and release handoff | [T6] |

## T1 — React/Vite feature architecture and provider scaffold

### Description

Scaffold the `dashboard` implementation repo as a React + Vite app and establish the feature-based architecture described in `technical-design.md`. This task creates the app shell, route/provider entry points, shared UI boundary, feature folder structure, and direct compound-component convention so later tasks can add domain logic and UI without inventing structure independently.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Confirm `/home/kadamato/Documents/dashboard` is the implementation repo for `repo: dashboard`.
- [ ] Scaffold React + Vite with TypeScript.
- [ ] Install and configure TanStack Router according to the app routing needs.
- [ ] Create `src/app/providers/AppProviders.tsx` and app-level provider composition.
- [ ] Create feature folders for `auth`, `workspaces`, `board`, `tasks`, and `errors`.
- [ ] Add public feature `index.ts` or `index.tsx` files.
- [ ] Document the direct compound assignment convention in code comments only where needed.
- [ ] Add baseline typecheck/build scripts.
- [ ] Verify the empty app builds.

## T2 — Workspace domain services and import provider

### Description

Implement the workspace domain layer behind Provider/Context. This task owns workspace persistence, default workspace seeding, repository URL parsing, duplicate detection, private repository token validation, and safe import payload creation. It must ensure raw GitHub personal access tokens remain transient React state and are never persisted to `localStorage`.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Create workspace domain types, including optional `privateRepository` and `tokenConfigured` metadata.
- [ ] Create safe localStorage helpers for auth/workspace reads and writes.
- [ ] Implement `WorkspacesProvider` with seeded defaults and CRUD helpers.
- [ ] Implement `WorkspaceImportProvider` with `url`, `privateRepository`, `token`, `error`, and `importing` state.
- [ ] Implement repository URL validation for `https://`, `http://`, and `git@`.
- [ ] Implement duplicate URL detection against existing workspaces.
- [ ] Require non-empty token only when `privateRepository` is enabled.
- [ ] Accept both classic and fine-grained GitHub token text by checking only non-empty value.
- [ ] Clear token on successful import, private switch off, and form reset.
- [ ] Verify raw token values are not stored in `localStorage`.

## T3 — Workspace list page compound components

### Description

Build the `/workspaces` page from compound workspace components. The route should become a thin shell that composes workspace list, import card, workspace cards, sign out action, and the disabled `Create a new workspace` placeholder while preserving the product spec behavior and Figma layout.

### Required skills
- frontend-engineer
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma

- Workspace page: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-490&t=l6DiKoWXEtl6DNSM-0

### Subtasks
- [ ] Read the Workspace page Figma frame before UI implementation.
- [ ] Implement `WorkspaceList` compound components.
- [ ] Implement `WorkspaceCard` UI and interactions.
- [ ] Implement `WorkspaceImport` compound UI using `WorkspaceImportProvider`.
- [ ] Add the `Private repository` switch and token field to the import card.
- [ ] Preserve import loading, duplicate error, invalid URL error, and private-token-required error behavior.
- [ ] Preserve workspace deletion with `preventDefault()` and `stopPropagation()`.
- [ ] Preserve sign out behavior and route guard behavior.
- [ ] Keep `Create a new workspace` visible but non-functional.
- [ ] Browser-check `/workspaces` against the Figma frame.

## T4 — Board shell, workspace switcher, and Add workspace modal

### Description

Build the workspace detail board shell around `BoardProvider` and workspace switching behavior. This task owns the board header, workspace switcher dropdown, `Add workspace` action, and `Add workspace` modal. The modal must reuse the shared workspace import provider behavior and keep `Create workspace` disabled.

### Required skills
- frontend-engineer
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma

- Workspace detail page: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-537&t=l6DiKoWXEtl6DNSM-0
- Switch workspace: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=36-935&t=l6DiKoWXEtl6DNSM-0

### Subtasks
- [ ] Read the Workspace detail and Switch workspace Figma frames before UI implementation.
- [ ] Implement `BoardProvider` state for current workspace identity, dropdown state, modal state, search query, filters, expanded features, and selected task.
- [ ] Implement `WorkspaceSwitcher` compound components.
- [ ] Add `Add workspace`, `Delete workspace`, and `Sign out` actions to the switcher dropdown.
- [ ] Implement `AddWorkspaceModal` with `Import repository` enabled.
- [ ] Keep `Create workspace` visible but disabled with `Coming soon` helper text.
- [ ] Reuse `WorkspaceImportProvider` in the modal.
- [ ] On successful modal import, close the modal and navigate to the new workspace board.
- [ ] Preserve click-outside close behavior for dropdowns and modal.
- [ ] Browser-check board header and switcher behavior against Figma.

## T5 — Kanban and task detail compound components

### Description

Split the monolithic Kanban/task UI into feature-based compound components while preserving sample data behavior. This task owns board columns, feature rows, segment tooltip, task cards, status filter dropdown, and task detail sheet. It should keep logic in provider/hooks and UI parts small.

### Required skills
- frontend-engineer
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma

- Workspace detail page: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-537&t=l6DiKoWXEtl6DNSM-0
- Filter task: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=35-752&t=l6DiKoWXEtl6DNSM-0
- Task detail: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=36-1108&t=l6DiKoWXEtl6DNSM-0

### Subtasks
- [ ] Read the Workspace detail, Filter task, and Task detail Figma frames before UI implementation.
- [ ] Move sample feature/task data into `features/board/model/sample-features.ts`.
- [ ] Implement `KanbanBoard` compound root and board layout.
- [ ] Implement status columns and count badges.
- [ ] Implement `StatusFilter` compound components with multi-select OR logic.
- [ ] Implement `FeatureRow` expand/collapse behavior.
- [ ] Implement `SegmentBar` custom tooltip behavior.
- [ ] Implement `TaskCard` actor badge and next-action behavior.
- [ ] Move `TaskDetailSheet` into the `tasks` feature with provider-backed state.
- [ ] Preserve task metadata, PR cards, timeline, and done-state footer action behavior.

## T6 — Route integration, fallback screens, and toast wiring

### Description

Integrate the feature modules into TanStack Router routes. Routes should be thin composition files and should not own import validation, workspace parsing, board filtering, or task sheet formatting. This task also wires fallback screens and visible toast support if required by the existing `toast.success("Code approved and merged")` behavior.

### Required skills
- frontend-engineer
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma

- Login page: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=14-2&t=l6DiKoWXEtl6DNSM-0
- Workspace page: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-490&t=l6DiKoWXEtl6DNSM-0
- Workspace detail page: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-537&t=l6DiKoWXEtl6DNSM-0

### Subtasks
- [ ] Read the Login, Workspace, and Workspace detail Figma frames before route integration touches UI.
- [ ] Implement thin `/` redirect route.
- [ ] Implement thin `/login` route composed from auth feature components.
- [ ] Implement thin `/workspaces` route composed from workspace feature components.
- [ ] Implement thin `/workspaces/:workspaceId` route composed from board/workspace/task feature components.
- [ ] Implement 404 fallback screen.
- [ ] Implement router error boundary screen.
- [ ] Mount toaster support if the app uses `toast.success` in done-task footer actions.
- [ ] Verify route guards and redirect behavior.
- [ ] Verify no route owns feature business logic after integration.

## T7 — End-to-end QA and release handoff

### Description

Run final validation across the complete dashboard feature and prepare handoff notes. This task verifies build/typecheck, route flows, import behavior, private token safety, board interactions, task detail sheet, and Figma-referenced visual surfaces. It does not approve the feature; it produces evidence for human review.

### Required skills
- frontend-engineer
- typescript-best-practices
- browser-qa-frontend

### Subtasks
- [ ] Run the app typecheck.
- [ ] Run the app build.
- [ ] Run available unit/component tests if configured.
- [ ] Browser-test `/`, `/login`, `/workspaces`, and `/workspaces/:workspaceId`.
- [ ] Verify public repository import still works.
- [ ] Verify private repository import requires a token.
- [ ] Verify raw GitHub token is not present in `localStorage.workspaces`.
- [ ] Verify modal import navigates to the new workspace board.
- [ ] Verify status filter dropdown and search behavior.
- [ ] Verify feature expand/collapse, segment tooltip, task card click, and task detail sheet.
- [ ] Verify workspace switcher delete/sign out actions.
- [ ] Capture any deviations from Figma or product spec in the handoff note.
