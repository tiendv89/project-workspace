# Tasks — Agent PR Response

**Feature status:** `in_tdd` → awaiting task approval  
**Stage:** task breakdown  
**Machine state:** lives in `tasks/T<n>.yaml` — this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Task schema — conflict_state + rebase fields | — |
| T2 | 1 | GitHub PR status poller | — |
| T3 | 2 | Auto-rebase handler | T1, T2 |
| T4 | 2 | Draft-state comment resolution dispatch | T1, T2 |

---

## T1 — Task schema — conflict_state + rebase fields

### Description
Extend `types/task.ts` with the new fields required by the PR response flows. All downstream tasks (T3, T4) write to these fields — the schema must be frozen before any runtime logic is added.

Adds:
- `ConflictState = "none" | "conflicted" | "resolving" | "resolved"` union type
- `RebaseLogEntry` interface `{ at, action, by, note }`
- `conflict_state?: ConflictState | null` field on `Task`
- `rebase_log?: RebaseLogEntry[]` field on `Task`
- `"pr_conflict"` added to `BlockedReason` union

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add `ConflictState` union type to `task.ts`
- [ ] Add `RebaseLogEntry` interface to `task.ts`
- [ ] Add `conflict_state` optional field to `Task` interface
- [ ] Add `rebase_log` optional field to `Task` interface
- [ ] Add `"pr_conflict"` to `BlockedReason` union
- [ ] Run full typecheck — zero errors

---

## T2 — GitHub PR status poller

### Description
New module `poll/check-in-review-prs.ts` that, for every `in_review` task in a workspace, calls `GET /repos/{owner}/{repo}/pulls/{pull_number}` and returns the current `mergeable` and `draft` state. Pure read — no task YAML mutations.

**Cycle ordering**: `ready` task pickup happens first in each cycle; `in_review` polling runs after. If a `ready` task is claimed, the cycle still completes the `in_review` pass. Results are passed to the T3/T4 handlers.

**Rate limiting**: a new `pr_poll_interval_seconds` field in `agent.yaml` (validated in `validate-agent-yaml.ts`) controls how often the `in_review` pass fires. The module skips the pass if it ran within that window. Default: same as `idle_sleep_seconds` (1 min). This field exists so operators can raise it to 5 min in production without code changes.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add `pr_poll_interval_seconds?: number` to `agent.yaml` schema in `validate-agent-yaml.ts` (optional, defaults to `idle_sleep_seconds`)
- [ ] Create `poll/check-in-review-prs.ts`
- [ ] Track `lastPrPollAt` timestamp in the cycle; skip the pass if `now - lastPrPollAt < pr_poll_interval_seconds`
- [ ] For each watched workspace, scan all features for `in_review` tasks with a non-null `pr.url`
- [ ] Extract GitHub owner/repo/pull_number from `pr.url`
- [ ] `GET /repos/{owner}/{repo}/pulls/{n}` with `Authorization: Bearer <GITHUB_TOKEN>`
- [ ] Return `PrStatusResult[]`: `{ taskId, featureId, mergeable: boolean | null, draft: boolean }`
- [ ] Handle API errors gracefully — emit `in_review_poll_error` event, skip that task
- [ ] Wire call into `runOneCycle` in `main.ts`: after `ready` task handling, before returning `"idle"` or `"ran_task"`
- [ ] Run full typecheck — zero errors

---

## T3 — Auto-rebase handler

### Description
New module `pr-response/auto-rebase.ts`. When T2 reports `mergeable: false` for a task, this handler:

1. Claims the rebase work: write `rebase_started` log entry to task YAML on the feature branch, push. If push is rejected (another agent claimed), skip this cycle.
2. In the implementation repo: `git fetch origin` then `git rebase origin/<base_branch>`.
3. **Clean rebase**: force-push the impl branch, update `conflict_state: resolved`, append `rebase_completed` log entry, push management repo.
4. **Conflicted rebase**: commit the conflict markers to the impl branch, set `task.status = "blocked"`, `blocked_reason = "pr_conflict"`, `conflict_state = "resolved"` (markers are pushed — the conflict is visible), append `rebase_blocked` log entry with file:line pointers in `blocked_suggestion`. Push both repos.

The first-push-wins claim pattern reuses the same mechanism as `claim-task.ts`.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Create `pr-response/auto-rebase.ts`
- [ ] Implement claim-via-first-push (write `rebase_started` log, push feature branch)
- [ ] `git fetch origin` + `git rebase origin/<base_branch>` in impl repo
- [ ] Parse rebase exit code to distinguish clean vs conflicted
- [ ] Clean path: `git push --force-with-lease`, update YAML fields, push mgmt repo
- [ ] Conflicted path: stage conflict markers (`git add`), commit, update YAML to blocked, push both repos
- [ ] Emit `rebase_completed` / `rebase_blocked` / `rebase_claim_lost` events
- [ ] Wire into `runOneCycle` in `main.ts`: iterate T2 results where `mergeable === false`
- [ ] Run full typecheck — zero errors
- [ ] Run full test suite — all pass

---

## T4 — Draft-state comment resolution dispatch

### Description
Extends the cycle to dispatch Claude for `in_review` tasks where the GitHub PR is in `draft: true` state (as reported by T2). This is the human signal that comments need addressing.

Two parts:

**Part A — New skill `technical_skills/respond-to-review/SKILL.md`**: Instructions for Claude to read open PR review comments, address each one on the implementation branch, push, then convert the PR from draft back to ready-for-review. The skill must record `comments_addressed` in the task log.

**Part B — Dispatch wiring in `main.ts`**: When T2 reports `draft: true` for an `in_review` task, set up an agent context using `respond-to-review` as the active skill and dispatch Claude. Reuse the same `generateAgentContext` / `runClaude` pipeline with an adapted context string. The claim/lock protocol is the same as for `ready` tasks (first-push-wins via a `review_started` log entry on the feature branch).

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Create `technical_skills/respond-to-review/SKILL.md` with full execution instructions
- [ ] Skill: read open review comments via GitHub API `GET /repos/{owner}/{repo}/pulls/{n}/comments`
- [ ] Skill: address each comment on the impl branch, commit, push
- [ ] Skill: convert PR from draft to ready-for-review via `PATCH /repos/{owner}/{repo}/pulls/{n}` `{ draft: false }`
- [ ] Skill: append `comments_addressed` log entry to task YAML on feature branch
- [ ] Create `pr-response/dispatch-draft-review.ts` — claim + agent context setup
- [ ] Claim protocol: write `review_started` log entry, push feature branch (first-push wins)
- [ ] Generate adapted agent context that loads `respond-to-review` skill
- [ ] Wire into `runOneCycle` in `main.ts`: iterate T2 results where `draft === true`
- [ ] Run full typecheck — zero errors
- [ ] Run full test suite — all pass
