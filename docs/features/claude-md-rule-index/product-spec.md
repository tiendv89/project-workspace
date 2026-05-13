# Product Specification

## Feature
- Feature ID: `claude-md-rule-index`
- Title: CLAUDE.md rule index — slim root file with on-demand rule fragment lookup

## Problem

`CLAUDE.md` has grown into a large monolithic file (~500+ lines) that is injected in full into every executor context window, every turn. It includes task lifecycle rules, git safety rules, PR conventions, Figma propagation rules, management repo rules, environment resolution rules, execution contract rules, and more.

The cost problem is concrete: every token of `CLAUDE.md` is paid on every turn of every task — even when most of those rules are irrelevant to the current action. A backend engineer running a database migration does not need Figma propagation rules in context. A tech-lead writing a product spec does not need the git hard-reset safety protocol.

There is no mechanism to load rules selectively. The current approach is "inject everything always."

## Goals

1. **Slim root `CLAUDE.md`** — reduce the root file to ~50 lines containing only: project identity, 4–6 universal hard stops (the "never do X" invariants that must always be in context), and a rule index table mapping topics to rule fragment files.

2. **Rule fragment files** — split the current content into focused markdown files stored under `workflow/rules/`. Each file covers one concern. Agents read only the files relevant to the action they are about to take.

3. **Lookup instruction** — the slim CLAUDE.md instructs the agent: "Before performing any of the following actions, read the corresponding rule file." The index table makes the lookup unambiguous.

4. **`sync-workspace-rules` compatibility** — `CLAUDE.md` is assembled from `CLAUDE.shared.md` via `sync-workspace-rules`. The refactor must preserve this contract: shared rules live in the workflow repo (`CLAUDE.shared.md`) and are synced into each workspace's `CLAUDE.md`. The rule fragment files also live in the workflow repo under `workflow/rules/` and are accessed from there.

5. **No behaviour regression** — every rule that exists today must be reachable via the new structure. Nothing is deleted; rules are reorganised and made lazy-loadable.

## Non-goals

- Not removing any existing rules — this is a structural refactor, not a rules audit
- Not building automatic rule injection (the agent reads files on demand; no orchestrator plumbing needed)
- Not changing the `sync-workspace-rules` skill implementation — only the source content it syncs changes
- Not per-task rule injection by the orchestrator — agents self-serve via `Read`

## Rule fragment index (proposed)

| File | Contents |
|---|---|
| `workflow/rules/task-lifecycle.md` | Status transitions, auto-ready rule, log action names, log format rules |
| `workflow/rules/task-execution.md` | Execution contract, start rule, skill execution contract, commit-before-block |
| `workflow/rules/git.md` | Hard-reset safety, branch sync protocol, no-direct-push-to-main |
| `workflow/rules/pr.md` | PR title convention, rebase-before-PR, rebase-before-done, pr-create skill rule |
| `workflow/rules/management-repo.md` | Claim commit, task file scope, branch merge rule, dependency unblock rule, task branch rule |
| `workflow/rules/environment.md` | Env resolution, required values, SSH rules |
| `workflow/rules/figma.md` | Figma link propagation, MCP usage, frontend fidelity rules |
| `workflow/rules/narrative-state-split.md` | tasks.md vs task YAML responsibilities, product-spec write boundary |
| `workflow/rules/rag-gitnexus.md` | RAG-first read rule, GitNexus lookup priority rule |

## Success criteria

- Root `CLAUDE.md` is ≤ 60 lines after refactor
- All existing rules are present verbatim in fragment files — no content is lost
- An agent performing a git operation reads `workflow/rules/git.md` before acting
- An agent performing a PR operation reads `workflow/rules/pr.md` before acting
- `sync-workspace-rules` continues to work; workspaces receive the slim CLAUDE.md on next sync

## Dependency

None. This is a standalone refactor of the shared workflow configuration.
