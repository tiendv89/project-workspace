# Product Specification

## Feature
- Feature ID: `management-repo-governance`
- Title: Management Repo Governance

## Problem

The current workflow lacks a formal definition and enforcement of the management repo — the repository that stores all task YAML files, feature docs, and `CLAUDE.md`. This creates three concrete gaps:

1. **No claim commit.** `start-implementation` updates `T_x.yaml` locally but does not commit and push that claim to the management repo. Without an atomic commit, two agents can both believe they own the same task simultaneously.

2. **No management repo declaration.** `workspace.yaml` has no `management_repo` field. Workflow skills cannot reliably locate the management repo, so they cannot enforce the claim commit rule or validate task file scope.

3. **No agent approval or fleet governance.** There is no mechanism to approve which agents may act on a workspace, track which agent ran a task, or revoke an agent. The management repo is effectively open to anyone with repo access.

## Goals

- Define `management_repo` as a required field in `workspace.yaml`, pointing to the repo that holds task state.
- Update `start-implementation` to commit and push the claim (`T_x.yaml` set to `in_progress`) to the management repo on the task branch before any implementation work begins. Treat push rejection as a concurrency loss.
- Define an agent registration and approval model: how agents are onboarded to a workspace, how their access is scoped, and how it can be revoked.
- Provide tooling (scripts or skill) to initialise the management repo with its first commit and remote, so new workspaces can satisfy the claim commit rule from day one.

## Non-goals

- Changing the concurrency model for implementation repos (that is handled by T7 claim protocol).
- Enforcing fine-grained per-feature access control within the management repo.
- Building a UI for agent management.
