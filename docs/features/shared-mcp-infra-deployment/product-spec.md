# Product Specification

## Feature
- Feature ID: `shared-mcp-infra-deployment`
- Title: Shared MCP Services Deployment (RAG + GitNexus)

## Problem
RAG (`rag-server` + Qdrant) and GitNexus MCP servers are valuable to every agent runtime across every workspace, but today they run as workspace-local stacks. Each workspace pays the cost of bringing up its own Qdrant, rag-server, and GitNexus — including duplicate model downloads, duplicate repo analysis, and per-workspace operational toil. There is no shared deployment that multiple workspaces and multiple agent-runtime instances can point at. As we add more workspaces and run agent runtimes more frequently, the per-workspace stack becomes wasteful and a friction point for onboarding.

## Services in scope
The following services currently live in the per-workspace runtime compose template (`agent-workflow/runtime/orchestrator/templates/docker-compose.yml`) and are the target of this feature. The shared platform compose (`agent-workflow/docker-compose.platform.yml`) today hosts only Postgres / Redis / asynqmon / api-service — RAG and GitNexus are *not* yet shared.

### RAG stack (from `rag-service` repo)
| Service | Role | Port | MCP surface |
|---|---|---|---|
| `rag-server` | MCP server exposing retrieval over indexed prose/YAML/docs | `8001` | `mcp__rag-server__rag_query` |
| `qdrant` | Vector DB backing the index | `6333` (HTTP), `6334` (gRPC) | — |
| `indexer` | Background worker populating Qdrant from workspace content | — | — |

### GitNexus stack (from `git-nexus` repo)
| Service | Role | Port | MCP surface |
|---|---|---|---|
| `gitnexus-server` | MCP server exposing code-graph queries | `8002` | `mcp__gitnexus__query`, `__context`, `__impact`, `__detect_changes`, `__list_repos`, `__group_query` |
| `gitnexus-indexer` | Background worker running Tree-sitter AST analysis into a shared `gitnexus-data` volume | — | — |

In total, five services across two stacks are being lifted from per-workspace to shared infrastructure. The agent runtime consumes them via `RAG_MCP_URL` and `GITNEXUS_MCP_URL` (already supported by the runtime today), so the migration is primarily a deployment-topology change, not an application change.

## Goals
- Deploy `rag-server` (with Qdrant) and `gitnexus-mcp` as shared MCP services in our infrastructure, addressable by any workspace's agent runtime over the network.
- Provide a stable, documented endpoint contract (URL + auth) that the agent-runtime can consume via `RAG_MCP_URL` / `GITNEXUS_MCP_URL` style configuration.
- Support multi-tenancy / multi-workspace isolation at the data layer so workspace A cannot read workspace B's indexed content (e.g. namespace per workspace in Qdrant, per-repo scoping in GitNexus).
- Make local-only deployment (the existing per-workspace Docker Compose stack) still work, so individual developers can run offline; remote shared infra is opt-in via env config.
- Establish operational basics: health endpoints, logging, restart policy, backups for Qdrant volumes, and a clear story for upgrading the MCP servers without breaking existing workspaces.

## Non-goals
- Rewriting the MCP servers themselves — this feature deploys the existing `rag-service` and `git-nexus` repos as-is.
- Hosting on a public cloud provider with full HA/multi-region — initial deployment targets a single environment (e.g. internal infra) and can scale later.
- Replacing the per-workspace local-mode developer flow — local Compose remains the default for offline work.
- A new authn/authz system — we will use the simplest acceptable token-based scheme that integrates with how the runtime already passes credentials.
- Indexing scheduling / orchestration of when to re-index — that remains in scope of the existing agent-runtime / RAG features.
