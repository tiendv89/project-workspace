# Product Specification

## Feature
- Feature ID: `linear-mcp-integration`
- Title: Provider-Agnostic Work Item Import — Linear MCP Integration

## Problem

Work items (Bets and Tasks) are authored in Linear by product owners and tech leads.
Agents in the Workspace runtime have no visibility into these items and cannot begin
execution until a human manually transcribes them into feature/task scaffolds.

This creates a synchronization gap:
- Duplicate effort: every Linear issue must be hand-translated into a Workspace task YAML.
- Drift: Linear issues and Workspace tasks diverge the moment the import is done.
- Friction: the bottleneck is the human who must copy-paste between two systems.

We want agents to be able to pick up and execute Linear tasks automatically, with no
manual translation step.

---

## Goals

1. Import a Linear Bet (Project) into the Workspace as a Feature, including all its
   Issues as Task YAMLs, in a single CLI invocation.
2. Map the Linear hierarchy (Cycle → Bet → Issue) to Workspace concepts
   (Sprint → Feature → Task) consistently and traceably.
3. Design the integration behind a provider-agnostic adapter interface so that
   Jira, GitHub Projects, and other platforms can be added later with minimal
   new code.
4. Preserve a bidirectional reference between every Workspace Task and its origin
   Linear Issue so that status can be written back.
5. Allow agents to begin task execution immediately after import — no extra human
   steps beyond approval of the generated scaffolds.

---

## Non-goals

- Real-time webhook-driven sync (deferred to a follow-up feature).
- Modifying Linear issues from within the Workspace task execution flow (deferred).
- A UI for browsing or selecting Bets — this is a CLI/skill-driven workflow.
- Full bidirectional sync of every Linear field (comments, attachments, etc.).
- Supporting Linear's sub-issues as first-class Workspace tasks (they map to
  subtask checklist items inside the parent task YAML).

---

## Hierarchy Mapping

### Linear → Workspace

| Linear Entity | Workspace Entity | Notes |
|---|---|---|
| Organization | Workspace | No new entity; implicit context |
| Team | — | Not mapped; team context stored as metadata |
| **Cycle** | Sprint (metadata only) | Stored in `status.yaml` as `external_sync.cycle`; no new workspace entity in V1 |
| **Project (Bet)** | **Feature** | Core mapping unit — one Bet → one Feature |
| **Issue** | **Task** | One task YAML per issue |
| Sub-issue | Subtask checklist item | Inline in parent task YAML; no separate lifecycle |
| Issue status | Task status | See status mapping table below |
| Assignee | `execution.actor_type` | Unassigned or agent-tagged → `agent`; named human → `human` |
| Label | `execution.required_skills` hints | Parsed to match skill slugs; unmatched labels stored in metadata |
| Priority | `execution.priority` | urgent/high/medium/low |
| Blocking relations | `depends_on` | `blocks` relations translated to `depends_on` on the blocked task |

### Status Mapping

| Linear Status (canonical) | Workspace Task Status |
|---|---|
| Backlog / Todo | `todo` |
| In Progress | `in_progress` |
| In Review | `in_review` |
| Done | `done` |
| Cancelled | `cancelled` |
| (any custom blocked state) | `blocked` |

Custom team workflows are resolved at import time; unmapped statuses default to `todo`
and a warning is emitted.

---

## User Stories

**As a product owner**, I want to run a single command to import a Linear Bet into
the Workspace so that agents can pick up the tasks without any manual transcription.

**As a tech lead**, I want the imported task scaffolds to include all dependency
relationships from Linear so that the agent execution order is correct.

**As an agent operator**, I want each imported task YAML to carry a reference back
to its Linear issue URL so that I can trace Workspace execution back to the original
specification.

**As a platform engineer**, I want the import mechanism to sit behind an abstract
adapter interface so that I can add a Jira or GitHub Projects adapter later without
touching the core import skill.

---

## Proposed Architecture

### 1. Provider Adapter Interface

All external work-item providers implement a single normalized TypeScript interface.
The Workspace runtime resolves the correct adapter at runtime based on a `provider:`
field in `workspace.yaml`.

```
WorkItemAdapter (interface)
  ├── LinearAdapter      ← uses Linear MCP tools
  ├── JiraAdapter        ← future
  └── GitHubProjectsAdapter  ← future
```

**Normalized types** (provider-agnostic, emitted by every adapter):

```typescript
interface ExternalCycle {
  id: string;
  name: string;
  startDate?: string;
  endDate?: string;
}

interface ExternalBet {
  id: string;
  name: string;
  description?: string;
  cycleId?: string;
  externalUrl: string;
  provider: string;      // 'linear' | 'jira' | 'github-projects'
}

interface ExternalTask {
  id: string;            // provider-native ID (e.g. 'ABC-123')
  title: string;
  description?: string;
  status: WorkspaceTaskStatus;   // already normalized
  priority?: 'urgent' | 'high' | 'medium' | 'low';
  assigneeType: 'agent' | 'human';
  assigneeName?: string;
  labels: string[];
  dependsOn: string[];   // other ExternalTask IDs that block this one
  betId: string;
  externalUrl: string;
}
```

The `LinearAdapter` implements this interface using the Linear MCP server:
- `list_cycles` → `fetchCycles()`
- `list_projects` + filter by cycle → `fetchBets(cycleId?)`
- `linear://project/{id}/issues` resource → `fetchTasks(betId)`
- `update_issue` → `writeStatus(taskId, status)` (for future write-back)

### 2. New CLI Skills

**`/import-feature <provider> <bet-id>`**

Single-invocation skill that:
1. Resolves `.env` (calls `resolve-project-env`).
2. Instantiates the named adapter (e.g. `LinearAdapter`).
3. Fetches the Bet by `bet-id`.
4. Calls `init-feature` internally to create the directory scaffold.
5. Fetches all Issues under the Bet.
6. Generates one task YAML per issue, including:
   - Normalized status, priority, assignee type.
   - `depends_on` list derived from Linear blocking relations.
   - `external_ref` block (see schema below).
7. Writes `external_sync` metadata into `status.yaml`.
8. Generates a draft `tasks.md` narrative from issue titles/descriptions.
9. Commits and pushes to `feature/<feature-id>` branch.
10. Prints a summary: N tasks imported, dependency graph, any warnings.

**`/sync-feature <feature-id>`** *(V2 scope, defined here for architecture clarity)*

Incremental sync skill that:
1. Reads `external_sync.last_synced_at` from `status.yaml`.
2. Fetches issues updated after that timestamp.
3. For each changed issue, updates the corresponding task YAML status.
4. Does NOT overwrite fields the agent has already set (branch, pr.url, log entries).
5. Emits a diff summary.

### 3. Schema Extensions

**Task YAML — `external_ref` block** (new optional block):

```yaml
external_ref:
  provider: linear
  id: "ABC-123"
  url: "https://linear.app/team/issue/ABC-123"
  title: "Original Linear issue title at import time"
  imported_at: "2026-05-10T13:00:00+0700"
  last_synced_at: "2026-05-10T13:00:00+0700"
```

**`status.yaml` — `external_sync` block** (new optional block):

```yaml
external_sync:
  provider: linear
  bet_id: "proj_abc123"
  bet_url: "https://linear.app/team/project/proj_abc123"
  cycle_id: "cycle_xyz"
  cycle_name: "Cycle 4 — May 2026"
  last_synced_at: "2026-05-10T13:00:00+0700"
```

**`workspace.yaml` — `work_item_providers` block** (new optional block):

```yaml
work_item_providers:
  - id: linear
    adapter: linear-mcp
    mcp_server: https://mcp.linear.app/mcp
    auth_env: LINEAR_API_TOKEN
    default_team: TEAM_ID     # optional filter
  - id: jira                  # future example
    adapter: jira-rest
    base_url: https://org.atlassian.net
    auth_env: JIRA_API_TOKEN
```

### 4. Updated `/init-feature` Workflow

`/init-feature` itself does **not** change — it remains the manual, from-scratch
scaffold creator. The new `/import-feature` skill calls `init-feature` as a
sub-step and then enriches the output. This preserves the existing contract and
avoids coupling.

The call chain for an import is:

```
/import-feature linear proj_abc123
  └── resolve-project-env
  └── LinearAdapter.fetchBet(proj_abc123)
  └── /init-feature linear-mcp-integration      ← internal call, creates scaffold
  └── LinearAdapter.fetchTasks(proj_abc123)
  └── write T1.yaml … Tn.yaml                   ← one per issue
  └── write tasks.md                            ← narrative from issue titles
  └── update status.yaml with external_sync
  └── git commit + push → feature branch
```

---

## Workflow Integration

### Import flow (V1)

```
Linear                       /import-feature skill           Workspace repo
------                       ----------------------           --------------
Cycle
  └── Bet (Project)   ──────► fetchBet()
        └── Issues    ──────► fetchTasks()
              └── Blocking   ────────────────────────────►  T1.yaml … Tn.yaml
                  Relations                                  status.yaml
                                                             tasks.md
                                                             (feature branch pushed)
                                                                  │
                                                             Human reviews & approves
                                                                  │
                                                             Agents execute tasks
```

### Status write-back flow (V2, future)

```
Workspace task marked done
  └── hook fires → /sync-writeback T3
        └── LinearAdapter.writeStatus('ABC-456', 'Done')
              └── update_issue(id, status='Done')
```

---

## Future Extensibility

| Capability | How it is enabled |
|---|---|
| Add Jira adapter | Implement `WorkItemAdapter` interface; declare in `workspace.yaml` |
| Add GitHub Projects adapter | Same interface, different MCP/REST calls |
| Real-time webhook sync | Add `subscribe()` method to interface; V2 sync skill polls or subscribes |
| Cycle-level import | `/import-cycle linear <cycle-id>` loops over Bets, calls `/import-feature` per Bet |
| Status write-back | `writeStatus()` already defined in interface; wired up in V2 |
| Multi-cycle roadmaps | `ExternalCycle` already in normalized types; `status.yaml` can hold cycle array |

---

## Acceptance Criteria

- [ ] Running `/import-feature linear <bet-id>` on a clean workspace creates a valid
      feature scaffold (same structure as `/init-feature`) plus task YAMLs.
- [ ] Every task YAML contains an `external_ref` block with provider, ID, URL, and
      import timestamp.
- [ ] Dependency ordering from Linear blocking relations is faithfully represented in
      `depends_on` fields; no cycles are introduced.
- [ ] Issue status at import time is correctly mapped to Workspace task status using
      the status mapping table.
- [ ] `status.yaml` contains an `external_sync` block with bet ID, cycle name, and
      `last_synced_at`.
- [ ] A draft `tasks.md` is generated from issue titles and descriptions.
- [ ] All files are committed to `feature/<feature-id>` branch and pushed to origin.
- [ ] Running `/import-feature jira <project-key>` (stub) fails gracefully with
      "adapter not configured" — confirming the interface boundary is enforced.
- [ ] The `LinearAdapter` is the only place that references Linear-specific MCP tool
      names — no Linear-specific code leaks into the core import skill.
- [ ] `workspace.yaml` validation rejects a `work_item_providers` entry with an
      unknown `adapter` value.

---

## Open Questions

1. **Conflict resolution on re-import**: if `/import-feature` is run twice for the
   same Bet, should it overwrite, merge, or error? Recommendation: error with
   "feature already exists; use `/sync-feature` to update".

2. **Agent skill inference from labels**: should the adapter attempt to map Linear
   labels to `required_skills` slugs automatically, or should the tech lead do
   this manually post-import? Recommendation: attempt a best-effort match; emit
   a warning for labels that did not resolve.

3. **Cycle as a first-class Workspace entity**: should Cycles become a top-level
   directory (e.g. `docs/cycles/<cycle-id>/`) that groups Feature directories,
   or remain metadata-only? Recommendation: metadata-only in V1; revisit if
   reporting/dashboard features need a cycle-level aggregate view.

4. **Approval gate after import**: should the imported scaffold auto-advance to
   `awaiting_approval` or stay `draft`? Recommendation: stay `draft` — the
   tech lead should review the mapping before sending for approval.
