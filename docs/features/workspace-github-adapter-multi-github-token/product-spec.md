# Product Specification

## Feature
- Feature ID: `workspace-github-adapter-multi-github-token`
- Title: Multi GitHub Token Support for Workspace GitHub Adapter

## Problem

The workspace-github-adapter is built to serve multiple workspaces, but today it only supports a
single global GitHub token configured at startup (`configs.GitHubConfig.Token`). That token is
baked into the `github.Adapter` at construction time and used for every outbound GitHub API call
regardless of which workspace is being synced.

Concretely:

1. **Single global token** — `GitHubConfig.Token string` is one scalar. It is passed to
   `ghadapter.New(cfg.GitHub.Token)` once at startup and stored inside `Adapter.token`. Every
   `ImportWorkspace`, `SyncWorkspace`, `FetchFeature`, and `FetchTask` call uses this one
   credential.

2. **No per-workspace token routing** — `domain.GitHubWorkspaceAdapter.SyncWorkspace` takes
   `workspaceID`, `repoURL`, and `ref` but carries no token parameter. There is no mechanism to
   select a different credential based on which workspace is being synced.

3. **Cross-organisation access failure** — if an operator registers two workspaces where one lives
   in `github.com/org-A` and another in `github.com/org-B`, a single personal access token
   typically does not have read access to both. The adapter will silently fail to sync (or import)
   any workspace whose repo is outside the token's scope, with a misleading 401 / 404 from GitHub.

The result: an operator who manages workspaces across multiple GitHub organisations or accounts
cannot run a single shared adapter instance. They must either use a broad machine-user token (a
security risk), or deploy a separate adapter instance per organisation (operational overhead that
grows linearly with the number of orgs).

## Goals

1. Allow operators to configure a list of token entries in `config.yaml` — one per watched
   workspace or GitHub owner — so that each workspace can use its own GitHub credential.
2. Route outbound GitHub API calls to the correct token by matching the repo owner (or full
   `owner/repo`) of the target workspace before making the request.
3. Maintain backwards compatibility: operators with a single workspace can continue using the
   existing `github.token` scalar; the adapter upgrades it to the new multi-entry model
   transparently at startup.
4. Surface a clear configuration error at startup when a workspace is registered but no matching
   token entry covers its GitHub owner.

## Non-goals

- UI for managing tokens — config file and/or environment variables only.
- Automatic GitHub token rotation or refresh.
- GitHub App / installation token support (a separate feature).
- Changes to sync logic, task classification, branch routing, or queue behaviour — this feature is
  limited to config ingestion and per-workspace token resolution.
- Per-workspace webhook secret routing — that was addressed in
  `workspace-github-adapter-sync-multi-repo`.
