# Product Specification

## Feature
- Feature ID: `workspace-github-adapter-sync-multi-repo`
- Title: Workspace GitHub Adapter — Multi-Repo Webhook Support

## Problem

The workspace-github-adapter currently supports only a single GitHub repository per workspace and
a single global `webhook_secret` shared across all webhooks.

Concretely:

1. **Single webhook secret** — `configs/configs.go` defines `GitHubConfig.WebhookSecret string`
   (one value). Every incoming webhook is verified against this one secret. GitHub issues a
   per-repository secret when you register a webhook, so if any two repos have different secrets
   the adapter cannot verify one of them.

2. **Single repo per workspace** — `workspace_github_sources` has an `ON CONFLICT (workspace_id)`
   constraint that enforces at most one source record per workspace. Real workspace setups (e.g.
   management-repo, workflow-backend, digital-factory-ui, rag-service, …) involve many repos.
   Only the management repo is currently watchable via webhook.

3. **No per-repo secret routing** — the webhook handler calls `webhook.ReadAndVerify` with the
   global secret before it knows which repo sent the event. There is no mechanism to select the
   correct secret based on the incoming repo.

The result: teams that want push-triggered sync on more than one repo must run a separate adapter
instance per repo, which defeats the point of a shared workspace adapter.

## Goals

1. Allow operators to configure multiple `(repo_url, webhook_secret)` pairs in `config.yaml` so
   that each watched repo can carry its own GitHub-issued webhook secret.
2. Store multiple GitHub sources per workspace in the database — remove the one-source-per-workspace
   constraint.
3. Route incoming webhooks to the correct secret by extracting the repo identity from the push
   payload before signature verification, then looking up the matching secret from config.
4. Extend the `POST /internal/workspaces/import` endpoint (or add a new registration endpoint) so
   that additional repos can be attached to an existing workspace with a per-repo webhook secret.
5. Maintain backwards compatibility: operators with a single repo can continue using the existing
   `github.webhook_secret` scalar field; the adapter upgrades it to the new multi-repo model
   transparently.

## Non-goals

- Watching repos that belong to different GitHub accounts/organisations within the same workspace
  instance (GitHub App support is a separate feature).
- UI for managing webhook secrets (config file and API only).
- Automatic GitHub webhook registration (operators register webhooks on GitHub manually or via
  their own tooling; the adapter only consumes them).
- Changing the sync logic, task classification, or queue behaviour — this feature is limited to
  configuration ingestion, webhook routing, and DB schema for multi-repo.
