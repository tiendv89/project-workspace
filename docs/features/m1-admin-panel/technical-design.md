# Technical Design

## Feature
- Feature ID: `m1-admin-panel`
- Title: `M1 Admin Panel`

---

## 1. Current State

### user-service (Go / Gin)
The user-service owns all identity and membership data:
- `organizations` — tenancy boundary
- `memberships` — links a user to an org with a `role` string field (known values: `"member"`, `"platform_admin"`)
- `workspace_memberships` — scopes a user to a specific workspace within an org
- `organization_invitations` — pre-acceptance invitation records with `email`, `role`, `workspace_ids`, and `expires_at`

Core operations already exist in `internal/organizations/organizations.go`:
- `CreateInvitation(orgID, email, role, invitedBy, workspaceIDs, expiresAt)`
- `FindPendingInvitationByEmail(orgID, email)`
- `EnsureMembership(userID, orgID, role)`
- `EnsureWorkspaceMembership(userID, workspaceID)`
- `MembershipsByUser(userID)`
- `AccessibleWorkspaceIDs(userID)`

**Gap:** No HTTP handlers expose these operations. There are no admin-guarded endpoints for listing members, inviting users, or removing users from a workspace.

### workflow-backend (Go / Gin)
Owns workspace/feature/task records and delegates all auth to user-service via session cookie validation. Auth middleware (`RequireAuth`) calls user-service's `/sessions/validate` and attaches `AuthCtx{UserID, OrganizationID, AccessibleWorkspaceIDs}` to each request. No membership management lives here.

### digital-factory-ui (Next.js 16 / React 19 / HeroUI v3)
- `/src/app/admin/` — admin section exists with a layout guard that checks `role === "platform_admin"` in the user's memberships
- `SessionContext` + `WorkspaceContext` provide user identity and active workspace ID throughout the app
- React Query is the data-fetching layer; user-service calls go through `/src/services/user-service/client.ts`
- **Gap:** Only `/admin/connect` exists. There are no membership management pages.

---

## 2. Problem Framing

### What needs to change
1. **user-service** must expose admin HTTP endpoints to list workspace members, invite a user by email, remove a user from a workspace, list pending invitations, and cancel an invitation.
2. An **admin authorization middleware** must protect those routes — the calling user must have `role: "admin"` or `role: "platform_admin"` on their org membership.
3. **digital-factory-ui** must add an admin members page at `/admin/members` that consumes those endpoints.

### What must remain stable
- The existing `/api/me`, `/auth/:provider/...`, and `/sessions/validate` flows must not change.
- The role field in `memberships` is used today as a freeform string; no schema migration should break existing values.
- The admin layout guard in `digital-factory-ui` (`platform_admin` check) remains — the new page must live under the existing `/admin/` tree.

### Fixed assumptions
- Membership management is **workspace-scoped**: the admin panel shows and manages members of the currently active workspace.
- An org-level role (`admin` or `platform_admin`) grants access to the admin panel. Workspace-level roles are out of scope (non-goal: custom roles).
- Email delivery for invitations is **out of scope for M1**. The system creates the invitation record; sharing the invite link is manual in this milestone.

---

## 3. Options Considered

### Option A — Admin endpoints in user-service (chosen)
Add `/api/admin/workspace/:workspaceId/...` routes directly to user-service, protected by a new admin middleware that checks org membership role.

**Pros:**
- Ownership is unambiguous: user-service already owns membership/invitation tables and core operations.
- Minimal new code — handlers call existing internal functions.
- No cross-service HTTP call needed; auth context is already available in-process.

**Cons:**
- user-service gains HTTP surface; must be kept narrow.

**Implementation impact:** New handler file, new middleware function, no schema changes.
**Dependency impact:** UI depends on these endpoints being live.

### Option B — Admin endpoints in workflow-backend (proxy)
workflow-backend exposes admin routes and delegates to user-service internally via service-to-service calls.

**Pros:**
- Keeps user-service as a pure identity service.

**Cons:**
- Unnecessary indirection; workflow-backend has no membership tables.
- Adds a new inter-service call path with its own failure mode.
- Contradicts the existing pattern where the UI talks to user-service directly for auth/identity.

**Verdict:** Rejected — wrong service boundary.

---

## 4. Chosen Design

### Admin API (user-service)

New route group registered at `/api/admin`, guarded by `RequireAdminAuth` middleware:

```
GET    /api/admin/workspace/:workspaceId/members
POST   /api/admin/workspace/:workspaceId/invitations
GET    /api/admin/workspace/:workspaceId/invitations
DELETE /api/admin/workspace/:workspaceId/members/:userId
DELETE /api/admin/workspace/:workspaceId/invitations/:invitationId
```

`RequireAdminAuth`:
1. Calls existing session validation (reuse `RequireAuth` pattern).
2. Looks up the caller's `membership.role` for their `organization_id`.
3. Returns `403` if role is not `"admin"` or `"platform_admin"`.
4. Confirms the `workspaceId` param belongs to the caller's org (workspace ownership check).

**Response shapes (JSON):**

`GET .../members`:
```json
{
  "members": [
    { "user_id": "...", "email": "...", "display_name": "...", "role": "member" }
  ]
}
```

`GET .../invitations`:
```json
{
  "invitations": [
    { "id": "...", "email": "...", "role": "member", "expires_at": "..." }
  ]
}
```

`POST .../invitations` body: `{ "email": "...", "role": "member" }`

`DELETE .../members/:userId` — removes workspace_membership row; does **not** remove org membership.

`DELETE .../invitations/:invitationId` — deletes the pending invitation record.

### Admin Panel UI (digital-factory-ui)

New page at `/admin/members` under the existing `/admin/` layout (inherits `platform_admin` guard — role check will be broadened to include `"admin"` to match the API).

Page sections:
- **Members table** — columns: Name, Email, Role, Actions (Remove button). Fetched via `GET .../members`.
- **Invite form** — Email input + Invite button. Calls `POST .../invitations`.
- **Pending invitations table** — columns: Email, Role, Expires, Actions (Cancel button). Fetched via `GET .../invitations`.

State management: React Query hooks for each endpoint. Mutations invalidate the relevant query on success.

### Affected repositories
| Repo | Change |
|---|---|
| `user-service` | New admin handler file, new `RequireAdminAuth` middleware, new route registration |
| `digital-factory-ui` | New `/admin/members` page, new React Query hooks, extend admin layout role check |

---

## 5. Dependency Analysis

| Dependency | Status | Notes |
|---|---|---|
| `organizations.go` core ops | Available | `CreateInvitation`, `EnsureWorkspaceMembership`, etc. already exist |
| DB schema for memberships/invitations | Available | No migration needed for M1 |
| Admin role string (`"admin"`) | **Decision needed** | Currently only `"member"` and `"platform_admin"` are documented. Adding `"admin"` as a recognized value requires confirming with the team. Alternatively, the middleware can accept `"platform_admin"` only for M1. |
| Email delivery for invitations | **Out of scope — M1** | Invitation records are created; the invite link/token must be shared manually. Full email delivery is deferred. |
| Invite accept flow (invited user clicks link) | **Out of scope — M1** | Claiming an invitation is a separate feature. Admin panel only creates and cancels invitations. |
| Workspace ownership lookup (workspaceId → orgId) | Needs verification | user-service must verify the workspaceId param belongs to the caller's org. The `workspace` table likely lives in workflow-backend, not user-service. **If workspace ownership validation cannot be done inside user-service**, the middleware may need to rely on `AuthCtx.AccessibleWorkspaceIDs` from session validation instead of a DB lookup. This must be confirmed before T1 begins. |

**Open question (blocking T1):** Does user-service have direct access to the `workspaces` table, or does it infer workspace ownership entirely from `workspace_memberships`? If the latter, the admin check can validate `workspaceId ∈ AccessibleWorkspaceIDs` from the session rather than querying a workspaces table. The T1 implementer must resolve this before writing the middleware.

---

## 6. Parallelization / Blocking Analysis

```
T1: user-service — admin membership API
  └── Can begin now — no blockers
      (resolve workspace-ownership check pattern during implementation)

T2: digital-factory-ui — admin members page
  └── BLOCKED on T1 (API endpoints must exist before UI can call them;
      response shapes define the TypeScript types)
```

T1 and T2 are sequential. No parallelization opportunity — the UI is fully downstream of the API.

---

## 7. Repository Impact

| Repo | What changes | Why |
|---|---|---|
| `user-service` | New file `internal/handler/admin.go` (or similar); new `RequireAdminAuth` middleware; router registration in `main.go` or equivalent | Exposes membership management as HTTP endpoints |
| `digital-factory-ui` | New file `src/app/admin/members/page.tsx`; new React Query hooks in `src/services/user-service/`; update admin layout role check to include `"admin"` | Provides admin UI for membership management |

No changes to `workflow-backend`, `rag-service`, `workspace-github-adapter`, or any other repo.

---

## 8. Validation and Release Impact

### Testing expectations
- **user-service:** Integration tests for each admin endpoint — happy path, 401 (unauthenticated), 403 (non-admin), 404 (workspace not accessible). Use existing test patterns in the repo.
- **digital-factory-ui:** Component tests for the members page (mock React Query); E2E test for the invite → pending → cancel flow (optional for M1).

### Migration / config impact
- No DB schema migration required.
- No new environment variables for M1.
- If the `"admin"` role string is new, document it in user-service alongside existing role constants.

### Rollout concerns
- The `/api/admin/...` routes are net-new; no existing clients will break.
- The admin layout role-check broadening (`platform_admin` → `platform_admin | admin`) is backward-compatible.

### Backward compatibility
- Existing `/api/me`, auth, and session flows are untouched.
- No breaking changes to any existing endpoint.

### Deployment / handoff implications
- user-service must be deployed before digital-factory-ui (T1 before T2).
- No feature flag required; the new routes are additive.
- M1 does not include email delivery; teams should be aware that invitation records can be created but the accept flow is not yet wired.
