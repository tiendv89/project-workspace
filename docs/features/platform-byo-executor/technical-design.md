# Technical Design

## Feature
- Feature ID: `platform-byo-executor`
- Title: Bring-Your-Own-Executor — customer-supplied executor images on the platform
- **Status: deferred** — do not begin technical design until `runtime-portable-architecture` is `done`. This file is a placeholder.

## Why this is empty

Authoring a technical design before the architectural foundation has stabilised would force premature commitment. `runtime-portable-architecture` is the prerequisite; its outcome will inform many of this feature's decisions.

When this feature is activated, the technical design will need to address (at minimum):

- Push and pull production adapters built on the `ExecutorPort` contract delivered by `runtime-portable-architecture`.
- Work Registry service for the pull-family adapter.
- Runner agent binary + container for customer-side installation.
- Tenant management (identity, isolation, lifecycle).
- Image registration catalog and conformance test runner.
- Per-task scoped credential minting (e.g. GitHub App integration).
- Billing / metering pipeline.
- Self-service customer surface (dashboard, CLI).
- Resource quotas and fairness across tenants in the orchestrator pool.

The architectural reasoning behind these is recorded in `../runtime-portable-architecture/discussion-orchestrator-architecture.md`. That document is the canonical record; this technical design will reference it rather than restate it.

## References

- `product-spec.md` — long-term goals, deferred open questions, dependency on the architectural prerequisite
- `../runtime-portable-architecture/` — architectural foundation, system diagram, port catalogue, profile mechanism
