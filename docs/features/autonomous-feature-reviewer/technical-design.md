# Technical Design

## Feature
- Feature ID: `autonomous-feature-reviewer`
- Title: Autonomous Feature Reviewer

## Current State

Tasks currently open PRs targeting the base branch (`main`) directly. There is no feature branch. The human review surface is per-task. There is no mechanism to detect when base branch changes affect an in-progress feature.

The `autonomous-task-orchestrator` feature introduces a quality gate and auto-done transition for tasks. This feature builds on top of that: it changes where task PRs land (feature branch instead of base branch), adds a handoff generation step, and introduces a drift detection agent for in-handoff features.

## Constraints

- The orchestrator (from `autonomous-task-orchestrator`) owns task PR creation — it must be updated to target the feature branch, not the base branch.
- Feature branches must follow the existing branch naming convention extended with feature scope: `feature/{feature_id}`.
- Task branches continue to follow: `feature/{feature_id}-T{n}`.
- All existing CLAUDE.md branch rules apply within the feature branch scope.
- The feature reviewer agent must not mutate task YAMLs for tasks it does not own.
- The feature branch PR (feature → base) is the canonical human review surface; task PRs are internal to the feature and auto-merged by the orchestrator.

## Chosen Design

Two components built on top of the orchestrator:

**Component 1 — Feature branch lifecycle manager** (extension to orchestrator):
- Creates `feature/{feature_id}` from base branch at orchestrator start.
- Configures executor agents to open task PRs targeting `feature/{feature_id}`.
- When all tasks are `done`: generates handoff document, opens feature branch PR, transitions feature status to `in_handoff`.

**Component 2 — Feature reviewer agent** (new daemon):
- Polls all features in `in_handoff` status.
- On each poll, checks for new commits on the base branch since the feature branch was created.
- Classifies impact (task-level vs feature-level) using file overlap + semantic analysis against `technical-design.md`.
- Acts: auto-rebase (task-level) or escalate with structured report (feature-level).

## Architecture

```
Orchestrator (existing, extended)
  │
  ├── on start: create feature/{feature_id} from base branch
  ├── task PRs target: feature/{feature_id}  (not main)
  ├── on all tasks done:
  │     generate handoff doc
  │     open feature PR → base branch
  │     set feature status: in_handoff
  │
Feature Reviewer Daemon (new)
  │
  ├── poll: features with status in_handoff  (every 10 min)
  ├── for each: compare feature branch with base branch tip
  │     → no new commits: skip
  │     → new commits: classify
  │           file overlap check (git diff)
  │           semantic analysis (reviewer agent → Claude API)
  │     → task-level: rebase feature branch, notify
  │     → feature-level: escalate with structured report
  └── stop watching: when feature branch PR is merged
```

## Component Designs

### Feature Branch Lifecycle Manager (orchestrator extension)

**On orchestrator start for a feature:**

The orchestrator must be idempotent — the branch may already exist if the orchestrator was restarted or the branch was created manually.

```
git fetch origin

if origin/feature/{feature_id} exists:
    # Branch already exists — resume, do not reset
    git checkout feature/{feature_id}
    if git pull origin feature/{feature_id} fails (non-fast-forward / force-pushed):
        # Remote was force-pushed; discard stale local branch and re-checkout clean
        git checkout {base_branch}
        git branch -D feature/{feature_id}
        git checkout -b feature/{feature_id} origin/feature/{feature_id}
    # If status.yaml already has feature_branch_base_sha set, keep it (do not overwrite)
    # If feature_branch_base_sha is unset, compute the merge-base and record it:
    #   BASE_SHA=$(git merge-base feature/{feature_id} origin/{base_branch})
else:
    # Branch does not exist — create from base branch tip
    git checkout {base_branch} && git pull origin {base_branch}
    BASE_SHA=$(git rev-parse HEAD)
    git checkout -b feature/{feature_id}
    git push -u origin feature/{feature_id}
    # Record BASE_SHA in status.yaml as feature_branch_base_sha
```

`feature_branch_base_sha` is the merge-base of the feature branch and the base branch at the moment the feature branch was first created. The drift detector uses this SHA as its comparison baseline — "what was on main when this feature started." It must never be overwritten on restart.

**Task PR target change:**
The orchestrator passes `base: feature/{feature_id}` when creating task PRs via the GitHub API (instead of the repo's default base branch). No change to executor agents — they open PRs as today; the orchestrator controls the PR target.

**Handoff trigger (all tasks done):**
1. Generate `handoffs/handoff.md` in the management repo (see structure below).
2. Open a PR: `feature/{feature_id}` → `{base_branch}` via GitHub API.
3. Write the PR URL into `status.yaml` under `stages.handoff`.
4. Transition `feature_status` to `in_handoff`, `current_stage` to `handoff`.
5. Commit and push management repo changes on the feature branch.
6. Notify operator via escalation channel.

### Handoff Document Structure

```markdown
# Handoff — {feature_title}

## Summary
{1-3 sentence summary derived from product spec goals}

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — {title} | {pr_url} | {reviewer_agent_notes} |
...

## Deviations from Technical Design
{list of any deviations noted by executor agents or reviewer agent}

## Files Changed
{aggregate file list across all task PRs}

## Follow-up Items
{open risks or flagged items from reviewer agent notes}

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| Task T1 done | orchestrator | {ts} |
...
```

### Feature Reviewer Agent

**Poll loop (every 10 minutes):**
1. Read all `status.yaml` files — collect features with `feature_status: in_handoff`.
2. For each, resolve the feature branch and base branch.
3. Call GitHub API: `GET /repos/{owner}/{repo}/compare/{feature_branch}...{base_branch}` — get commits on base branch not yet in feature branch.
4. If no new commits: skip.
5. If new commits: run classification.

**Classification:**

Step 1 — File overlap check:
```
files_changed_on_base = [files in new base commits]
files_changed_by_feature = [union of files across all task PRs for this feature]
overlap = intersection(files_changed_on_base, files_changed_by_feature)
```
If `overlap` is empty: likely task-level. Proceed to rebase.
If `overlap` is non-empty: run semantic analysis before deciding.

Step 2 — Semantic analysis (Claude API call):
- Input: incoming diff, feature `technical-design.md`, list of overlapping files.
- Prompt: "Does the incoming change conflict with or invalidate the design assumptions in this technical design? Return JSON: `{ level: 'task' | 'feature', confidence: float, reason: string }`."
- If `level == 'task'` and `confidence >= threshold`: auto-rebase.
- If `level == 'feature'` or `confidence < threshold`: escalate.

**Auto-rebase path:**
```
git fetch origin
git checkout feature/{feature_id}
git rebase origin/{base_branch}
git push --force-with-lease origin feature/{feature_id}
```
Notify operator: "Feature branch rebased onto new base (no design conflicts detected)."

**Escalation path:**
Generate structured report (see product spec format). Send to Slack webhook. Do not rebase. Mark feature with `drift_detected: true` and `drift_reason` in `status.yaml`. Wait for human to resolve before next poll cycle.

### status.yaml additions

```yaml
feature_branch: feature/{feature_id}
feature_branch_base_sha: abc1234   # base branch tip at feature branch creation
handoff_pr_url: null               # set when feature PR is opened
drift_detected: false
drift_reason: null
```

## Dependency Analysis

- **Depends on `autonomous-task-orchestrator`**: the feature branch lifecycle manager is an extension of the orchestrator. The reviewer daemon operates on features the orchestrator manages.
- **GitHub API**: compare endpoint for drift detection, PR creation for feature PR. Uses existing `GITHUB_TOKEN`.
- **Claude API**: semantic analysis call in the reviewer agent. Uses existing `ANTHROPIC_API_KEY`.
- **Slack webhook**: escalation. Uses `SLACK_WEBHOOK_URL`.
- **Management repo write access**: handoff doc commit, status.yaml updates. Uses existing SSH key.

## Parallelization / Blocking Analysis

- Feature branch lifecycle manager (orchestrator extension) must be built before the reviewer daemon — the daemon assumes the feature branch model is in place.
- Handoff document generation and feature PR opening can be built in parallel with the drift detection logic.
- `status.yaml` schema additions (new fields) should be done first as T1 — both components depend on them.
