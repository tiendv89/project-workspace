# Product Specification

## Feature
- Feature ID: `agent-registration`
- Title: Agent Registration and Approval

## Problem

There is no mechanism to approve which agents may act on a workspace, track which agent ran a task, or revoke an agent. The management repo is effectively open to anyone with repo access — there is no formal onboarding, scoping, or offboarding model.

## Context

The following gaps that originally motivated this feature have already been resolved:
- `management_repo` field in `workspace.yaml` — shipped
- Claim commit in `start-implementation` (push rejection = concurrency loss) — shipped
- Management repo initialisation tooling (`init-workspace` skill) — shipped

## Goals

- Define an agent registration model: how agents are onboarded to a workspace and what identity they carry when acting on tasks.
- Define an agent approval model: how a workspace operator approves an agent before it can claim or execute tasks.
- Define a revocation model: how an agent's access is removed and what happens to any in-flight tasks it holds.
- Scope agent access: whether access is workspace-wide or per-feature/per-task, and how that is declared.

## Non-goals

- Enforcing fine-grained per-feature access control within the management repo.
- Building a UI for agent management.
- Changing the concurrency model for implementation repos.
- Claim commit mechanics (already shipped).
