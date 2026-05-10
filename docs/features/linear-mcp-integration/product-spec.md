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
| Cycle | — | Out of scope in V1; ignored during import |
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
- `list_projects` → `fetchBets()`
- `linear://project/{id}/issues` resource → `fetchTasks(betId)`
- `update_issue` → `writeStatus(taskId, status)` (for future write-back)

### 2. Authentication

The Linear MCP server uses **OAuth 2.1** and is accessed exclusively by a human
running `/import-feature` locally in Claude Code. Agent runtime execution is out
of scope for V1.

**One-time setup:**

```bash
# Register the MCP server in Claude Code:
claude mcp add --transport http linear-server https://mcp.linear.app/mcp

# Trigger the OAuth browser flow:
/mcp
```

Claude Code caches the OAuth token in `~/.mcp-auth`. Subsequent calls reuse it
automatically. If the token expires, Claude Code prompts for re-authentication.

To reset: `rm -rf ~/.mcp-auth`

**Pre-flight check in the skill:**

Before making any Linear MCP calls, `/import-feature` checks whether `linear-server`
is registered in Claude Code's MCP config. If not, it prints the setup command above
and exits — no partial state is written.

**`workspace.yaml` — `work_item_providers` schema:**

```yaml
work_item_providers:
  - id: linear
    adapter: linear-mcp
    mcp_server: https://mcp.linear.app/mcp
    default_team: TEAM_ID     # optional — filter projects to this team
  - id: jira                  # future example
    adapter: jira-rest
    base_url: https://org.atlassian.net
    auth_token_env: JIRA_API_TOKEN
```

### 2. Unified `/import-feature` Skill

`/import-feature` is the single entry point for all feature creation — both manual
and provider-imported. It is backward compatible: the existing `<feature-id>` calling
convention is preserved exactly.

**Mode A — manual scaffold (existing behavior, unchanged)**

```
/import-feature <feature-id>
```

Behaves identically to the current `/init-feature` flow:
creates the empty scaffold (`product-spec.md`, `technical-design.md`, `status.yaml`,
`tasks/`, `handoffs/`) from templates and commits to `feature/<feature-id>`.
No provider is contacted. No schema extensions are written.

**Mode B — provider import (new)**

```
/import-feature --provider <provider> <bet-id>
```

Single-invocation skill that:
1. Resolves `.env` (calls `resolve-project-env`).
2. Instantiates the named adapter (e.g. `LinearAdapter`).
3. Fetches the Bet by `bet-id`; derives `<feature-id>` from the Bet slug.
4. Runs the Mode A scaffold creation for the derived `<feature-id>`.
5. Fetches all Issues under the Bet.
6. Generates one task YAML per issue, including:
   - Normalized status, priority, assignee type.
   - `depends_on` list derived from blocking relations.
   - `external_ref` block (see schema below).
7. Writes `external_sync` metadata into `status.yaml`.
8. Generates a draft `tasks.md` narrative from issue titles/descriptions.
9. Commits and pushes to `feature/<feature-id>` branch.
10. Prints a summary: N tasks imported, dependency graph, any warnings.

**Dispatch logic (inside the skill):**

```
args = parse(argv)

if args.has_flag("--provider"):
    run_mode_b(provider=args.flag("--provider"), bet_id=args.positional(0))
elif args.positional(0):
    run_mode_a(feature_id=args.positional(0))
else:
    error("Usage:")
    error("  /import-feature <feature-id>")
    error("  /import-feature --provider <provider> <bet-id>")
```

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
  last_synced_at: "2026-05-10T13:00:00+0700"
```

### 4. Skill Migration

`/init-feature` is superseded by `/import-feature`. The existing `/init-feature`
behavior becomes Mode A of `/import-feature`; the skill body is moved, not rewritten.

| Invocation | Behaviour | Backward compatible? |
|---|---|---|
| `/import-feature <feature-id>` | Existing init-feature scaffold, no provider | Yes — identical output |
| `/import-feature --provider <provider> <bet-id>` | Provider import, fills scaffold from external issues | New |

The internal call chain for Mode B:

```
/import-feature --provider linear proj_abc123
  └── resolve-project-env
  └── LinearAdapter.fetchBet(proj_abc123)      → derive feature-id from Bet slug
  └── run_mode_a(feature-id)                   ← existing scaffold creation, unchanged
  └── LinearAdapter.fetchTasks(proj_abc123)
  └── write T1.yaml … Tn.yaml                  ← one per issue
  └── write tasks.md                           ← narrative from issue titles
  └── update status.yaml (external_sync block)
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
| Status write-back | `writeStatus()` already defined in interface; wired up in V2 |

---

## Acceptance Criteria

- [ ] Running `/import-feature --provider linear <bet-id>` with `linear-server` MCP
      not registered prints the `claude mcp add` setup command and exits cleanly —
      no partial state is written.
- [ ] Running `/import-feature <feature-id>` (Mode A) produces output identical to
      the current `/init-feature` — empty scaffold, no `external_ref` or `external_sync`
      blocks, no provider contacted.
- [ ] Running `/import-feature --provider linear <bet-id>` (Mode B) on a clean workspace creates
      a valid feature scaffold plus populated task YAMLs.
- [ ] Every task YAML contains an `external_ref` block with provider, ID, URL, and
      import timestamp.
- [ ] Dependency ordering from Linear blocking relations is faithfully represented in
      `depends_on` fields; no cycles are introduced.
- [ ] Issue status at import time is correctly mapped to Workspace task status using
      the status mapping table.
- [ ] `status.yaml` contains an `external_sync` block with bet ID, bet URL, and
      `last_synced_at`.
- [ ] A draft `tasks.md` is generated from issue titles and descriptions.
- [ ] All files are committed to `feature/<feature-id>` branch and pushed to origin.
- [ ] Running `/import-feature --provider jira <project-key>` (stub) fails gracefully with
      "adapter not configured" — confirming the interface boundary is enforced.
- [ ] The `LinearAdapter` is the only place that references Linear-specific MCP tool
      names — no Linear-specific code leaks into the core import skill.
- [ ] `workspace.yaml` validation rejects a `work_item_providers` entry with an
      unknown `adapter` value.

---

## Decisions

1. **Conflict resolution on re-import**: `/import-feature --provider <provider> <bet-id>`
   must error with "feature already exists; use `/sync-feature` to update" if the
   feature directory already exists. No overwrite, no merge.

2. **Agent skill inference from labels**: the adapter performs a best-effort match of
   Linear labels to `required_skills` slugs. Unmatched labels are stored as raw
   metadata and a warning is emitted at import time. The tech lead reviews and
   corrects after import.

3. **Cycles**: out of scope. Cycle metadata is not captured, not stored in
   `status.yaml`, and not referenced by any skill or schema in V1.

4. **Approval gate after import**: imported scaffold stays `draft`. The tech lead
   must review the mapping and explicitly submit for approval via `/approve-feature`.
