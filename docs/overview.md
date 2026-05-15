# Overview

## 1. Project Summary
- **Workspace ID**: `workspace`
- **Project Name**: workspace
- **Purpose**:
  A rentable autonomous software delivery platform. Companies rent the agent fleet to execute code against their own specifications and repos. Each company (tenant) gets an isolated workspace — scoped agents, isolated RAG index, and isolated workflow state.

## Business Goal

The end-state is a **multi-tenant platform**: companies pay to use the agent fleet to build software against their specifications. This means every system that stores state per-workspace (RAG index, workflow DB, agent config) must include a `workspace_id` discriminator in its data model from day one — even if v1 operates with a single tenant. Multi-tenancy is a first-class future requirement, not an afterthought.

## 2. Roles in this Workspace
Document only roles actually used in this workspace.

## 3. Repositories
Use `workspace.yaml` as source of truth. Summarize repos here for humans.

## 4. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     TENANT (Company)                        │
│  workspace: their repos, specs, tasks, permissions          │
└────────────────────┬────────────────────────────────────────┘
                     │ scoped by workspace_id
          ┌──────────▼──────────────────────────┐
          │         WORKFLOW LAYER              │
          │  Features → Tasks → Review → Done   │
          │  Git YAML  →  workflow-db (Postgres) │
          │  dashboard (live queries)            │
          └──────┬──────────────┬───────────────┘
                 │ reads tasks  │ writes state
    ┌────────────▼──┐    ┌──────▼────────────────┐
    │  AGENT FLEET  │    │  RAG / MCP SERVER     │
    │               │    │                       │
    │ distributed-  │◄───│ indexes: skills, task │
    │ agent-team    │    │ logs, docs, ADRs       │
    │               │    │ query tool mid-task    │
    │ polling-loop  │    │ workspace_id scoped    │
    │ Docker/K8s    │    └───────────────────────┘
    │               │
    │ execution-env │  ← per-repo toolchain
    │ (Python/Go/..)│    (devcontainer / .tool-versions)
    └───────────────┘
```

### Feature map

| Feature | Role | Status |
|---|---|---|
| `feature-status-dashboard` | Live view of feature/task state | Done |
| `distributed-agent-team` | Agents self-activate, claim tasks, do work, submit for review — no human dispatcher | In design |
| `agent-runtime-polling-loop` | Keeps agents alive between cycles; git pull not re-clone | In design |
| `agent-execution-environment` | Agents can work on any language repo via per-repo toolchain declaration | In design |
| `workflow-db` | Moves YAML state to Postgres; enables live dashboard and DB-backed claim protocol | In design |
| `agent-rag-mcp` | Gives agents project knowledge at claim time + on-demand mid-task; replaces cold-start discovery | In design |

## 5. Database Schema

### Location and format

The canonical database schema lives at `database/schema.dbml` (repo root). This file is the **single source of truth** for the current applied schema.

Format: [DBML](https://dbml.org) — paste `database/schema.dbml` into [dbdiagram.io](https://dbdiagram.io) to visualise the current schema.

### Version history

Past schema versions are stored under `database/v<NNN>/`:

```
database/
├── schema.dbml        ← current applied schema (always up to date)
├── v001/
│   ├── changelog.md   ← what changed and why
│   └── schema.dbml    ← schema snapshot at this version
├── v002/
│   ├── changelog.md
│   └── schema.dbml
```

Version folders are numbered sequentially (`v001`, `v002`, …). `v001` is the oldest. The root `schema.dbml` always reflects the newest applied version.

### Rules for contributors

- Every schema change must create a new version folder (`v002`, `v003`, …) with `changelog.md` and `schema.dbml`.
- After creating the version folder, update `database/schema.dbml` to match.
- `changelog.md` must describe which tables were added, altered, or dropped, and why.
- All physical names (tables, columns, indexes, constraints) use lowercase `snake_case`.
- Every table must include a `workspace_id` column for multi-tenancy partitioning, even in single-tenant v1.

## 6. Environments
Document whether this workspace uses:
- develop
- staging
- production

## 7. Automation Policy
Summarize:
- which roles can later be handled by agents
- which steps remain human-only
- how reviews and approvals are handled
