# Product Specification

## Feature
- Feature ID: `workspace-github-adapter-sync-multi-repo`
- Title: Workspace GitHub Adapter — Multi-Workspace Webhook Support

## Problem

The workspace-github-adapter is designed to serve multiple workspaces (each backed by a GitHub
management repo), but a single global `webhook_secret` in config prevents it from doing so in
practice.

Concretely:

1. **Single global webhook secret** — `configs/configs.go` defines
   `GitHubConfig.WebhookSecret string` (one scalar). Every incoming push webhook is verified
   against this one secret, regardless of which workspace sent it. GitHub generates a per-repo
   secret when you register a webhook, so if two workspaces use different secrets, the adapter
   can only correctly verify one of them.

2. **No per-workspace secret routing** — `webhook.ReadAndVerify` receives the global secret
   before it knows which workspace sent the event. There is no mechanism to select the right
   secret based on the incoming repo, so operators running multiple workspaces on a single
   adapter instance must either share one secret across all their GitHub repos (a security
   anti-pattern) or run a separate adapter instance per workspace.

The result: teams cannot operate a single shared adapter instance that handles push-triggered
sync for multiple independent workspaces. Each workspace needs its own dedicated deployment,
which multiplies infrastructure cost and operational burden.

## Goals

1. Allow operators to configure a list of `webhook_secret` entries in `config.yaml` — one per
   watched workspace — so that each workspace can carry its own GitHub-issued webhook secret.
2. Route incoming webhooks to the correct secret by extracting the repo identity from the push
   payload before signature verification, then looking up the matching per-workspace secret.
3. Maintain backwards compatibility: operators with a single workspace can continue using the
   existing `github.webhook_secret` scalar; the adapter upgrades it to the new multi-entry
   model transparently at startup.
4. Ensure the adapter rejects any webhook whose repo does not match a registered workspace, so
   unrecognised push events are dropped early (before body processing).

## Non-goals

- Watching repos that are not management repos for a registered workspace (arbitrary repo
  webhooks are out of scope).
- UI for managing webhook secrets — config file and/or environment variables only.
- Automatic GitHub webhook registration — operators register webhooks on GitHub manually;
  the adapter only consumes them.
- Changes to sync logic, task classification, branch routing, or queue behaviour — this feature
  is limited to config ingestion and webhook secret routing.
- GitHub App support (a separate feature).
