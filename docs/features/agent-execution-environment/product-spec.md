# Product Specification

## Feature
- Feature ID: `agent-execution-environment`
- Title: Per-repo execution environment for agent tasks

## Problem

The distributed-agent-team feature (v1) packages a single Node.js-based Docker image that can run TypeScript tasks natively. However, when an agent needs to execute a task against a Python, Go, or other-language repository — writing code, running tests, linting — it lacks the required language runtime, package manager, and project-specific toolchain.

Without a solution, agents can only work on repos whose stack matches the agent image's installed runtimes. This limits fleet utility as the workspace grows to cover multiple languages and frameworks.

## Goals

1. **Agents can execute tasks against repos in any language** — Python, Go, Rust, etc. — without requiring a custom agent image per stack.
2. **Each repo owns its execution environment definition** — the repo author declares what runtime/toolchain the repo needs; agents consume that declaration at task time.
3. **No manual operator intervention per language** — adding a new Python repo to the workspace should not require rebuilding the agent image or changing agent config.
4. **Reproducible environments** — two agents running the same task against the same repo commit get the same toolchain versions.

## Non-goals

1. GPU-accelerated workloads or specialized hardware requirements (deferred).
2. Long-running services (databases, message brokers) as part of the execution environment — agents run tests, not integration stacks (use docker-compose separately if needed).
3. Replacing CI/CD — this is about giving agents a shell with the right tools, not about building a general pipeline runner.
4. Cross-repo environment sharing — each repo's environment is independent.

## Context

The distributed-agent-team technical design (v1) notes this gap in T9's Docker image spec. The current image is `node:20-alpine + git + openssh-client`. For v1, this is sufficient because all tasks target the workflow repo (TypeScript). This feature addresses the v2 need when the fleet serves heterogeneous repos.

## Prior art

- **Dev Containers (devcontainer.json)** — VS Code / GitHub Codespaces standard for declaring reproducible development environments. Well-documented, OCI-based, broad language support.
- **Nix / devenv** — hermetic, reproducible, language-agnostic. Steeper learning curve.
- **mise / asdf (.tool-versions)** — lightweight polyglot version manager. Installs language runtimes on demand. Not fully hermetic but practical.
- **Repo-provided Dockerfile.dev** — custom, per-repo, full control. No standard.

## Open questions

1. Which environment declaration format should repos use? (`devcontainer.json`, `.tool-versions`, `Dockerfile.dev`, or something else?)
2. Should the agent build the environment on every activation, or cache it across runs?
3. How does the agent runtime (Node.js orchestration) communicate with the task execution environment (different container or shell)?
4. What happens when the environment build itself fails — how does the agent report it?
5. Should `workspace.yaml` or `tasks.md` declare which repos need a custom execution environment, or should the agent auto-detect from repo contents?
