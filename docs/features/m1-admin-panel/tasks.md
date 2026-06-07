# Task Breakdown — M1 Admin Panel

Feature status: `in_tdd` | Stage: `tasks` (awaiting approval)
Machine state lives in `tasks/T<n>.yaml` — do not add status/log fields here.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | user-service: Admin membership API | — |
| T2 | 2 | digital-factory-ui: Admin members page | T1 |

---

## T1 — user-service: Admin membership API

### Description
Add admin-guarded HTTP endpoints to user-service that expose the existing membership and invitation
operations as a REST API. This is a pure HTTP exposure task — all DB-level operations
(`CreateInvitation`, `EnsureWorkspaceMembership`, `AcceptInvitation`, etc.) already exist in
`internal/organizations/organizations.go`. No schema migrations required.

**Endpoints to add** (route group: `/api/admin`):

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/admin/workspace/:workspaceId/members` | List all members of a workspace |
| `POST` | `/api/admin/workspace/:workspaceId/invitations` | Create an invitation (email + role) |
| `GET` | `/api/admin/workspace/:workspaceId/invitations` | List pending invitations for a workspace |
| `DELETE` | `/api/admin/workspace/:workspaceId/members/:userId` | Remove a user from a workspace (workspace_membership only) |
| `DELETE` | `/api/admin/workspace/:workspaceId/invitations/:invitationId` | Cancel a pending invitation |

**`RequireAdminAuth` middleware** (to protect all `/api/admin` routes):
1. Reuse existing session validation to populate `AuthCtx` (UserID, OrganizationID, AccessibleWorkspaceIDs).
2. Look up the caller's `membership.role` for their `OrganizationID`.
3. Return `403` if role is not `"admin"` or `"platform_admin"`.
4. Validate `workspaceId` param is within the caller's `AccessibleWorkspaceIDs` (use session context — no extra DB call needed since the session already carries this list).

**Invitation flow note:** Invitations are accepted automatically when the invited user logs in via
OAuth — `UpsertIdentityAndConsumeInvitations` already handles this in `internal/service/identity.go`.
The admin only needs to create and cancel invitation records; the accept flow is wired.

**`DELETE .../members/:userId`** removes the `workspace_membership` row only — does not affect
org-level membership or other workspaces the user may belong to.

### Required skills
- go-best-practices
- backend-engineer

### Subtasks
- [ ] Create `internal/handler/admin.go` with handler functions for all 5 endpoints
- [ ] Implement `RequireAdminAuth` middleware (reuse session validation, role check, workspace scope check)
- [ ] Register `/api/admin` route group in router (main.go or router.go)
- [ ] Implement `GET .../members` — query workspace_memberships joined with users for the workspace
- [ ] Implement `POST .../invitations` — call `CreateInvitation`; set `workspace_ids: [workspaceId]`, `role` from body, `expires_at: +7 days`
- [ ] Implement `GET .../invitations` — query pending invitations filtered by workspace_id in JSONB array
- [ ] Implement `DELETE .../members/:userId` — delete workspace_membership row
- [ ] Implement `DELETE .../invitations/:invitationId` — delete invitation record (verify it belongs to caller's org before deleting)
- [ ] Write integration tests for each endpoint: happy path, 401, 403, 404
- [ ] Run `golangci-lint` and full test suite; fix all errors before opening PR

---

## T2 — digital-factory-ui: Admin members page

### Description
Add a members management page at `/admin/members` inside the existing `/admin/` layout. The page
consumes the T1 endpoints and provides three interactive sections:

1. **Members table** — lists current workspace members (name, email, role). Each row has a Remove button that calls `DELETE .../members/:userId`.
2. **Invite form** — email input + role selector (default: "member") + Invite button that calls `POST .../invitations`. On success, invalidates the pending invitations query.
3. **Pending invitations table** — lists invitations where `accepted_at IS NULL` (email, role, expires). Each row has a Cancel button calling `DELETE .../invitations/:invitationId`.

**Implementation notes:**
- Use React Query for all data fetching and mutations (consistent with existing patterns).
- Active workspace ID comes from `WorkspaceContext`.
- User-service base URL from `NEXT_PUBLIC_USER_SERVICE_URL` env var.
- Add new typed client functions to `src/services/user-service/client.ts`.
- Update admin layout role guard (`src/app/admin/layout.tsx`) to accept `"admin"` in addition to `"platform_admin"`.
- Use HeroUI v3 components (Table, Input, Button, Modal for confirmation dialogs).
- The invitation acceptance flow is fully handled server-side — no UI needed for it.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices

### Subtasks
- [ ] Add typed API functions to `src/services/user-service/client.ts` for all 5 admin endpoints
- [ ] Add TypeScript types for `Member` and `Invitation` to `src/services/user-service/types.ts`
- [ ] Create React Query hooks: `useWorkspaceMembers`, `useWorkspaceInvitations`, `useInviteMember`, `useRemoveMember`, `useCancelInvitation`
- [ ] Create `src/app/admin/members/page.tsx` with members table, invite form, and pending invitations table
- [ ] Update `src/app/admin/layout.tsx` role guard to include `"admin"` alongside `"platform_admin"`
- [ ] Add confirmation modal/dialog before Remove and Cancel actions
- [ ] Handle loading, empty, and error states for both tables
- [ ] Test invite → pending invite appears; cancel → invite disappears; remove → member disappears
- [ ] Run type-check (`tsc --noEmit`) and lint; fix all errors before opening PR
