# Technical Design

## Feature
- Feature ID: `autonomous-feature-reviewer`
- Title: Autonomous Feature Reviewer

## Current State

Tasks currently open PRs targeting the base branch (`main`) directly. There is no feature branch. The human review surface is per-task. There is no mechanism to detect when base branch changes affect an in-progress feature.

The `autonomous-task-orchestrator` feature introduces: feature branch creation, task PR routing to the feature branch, quality gate, auto-done writer, handoff document generation, and the `in_handoff` transition. This feature builds on top of that: it adds a drift detection daemon that watches features the orchestrator has moved to `in_handoff`, and acts when new commits on the base branch may conflict with the in-progress feature.

## Constraints

- Feature branches and handoff documents are created by the `autonomous-task-orchestrator` — this feature does not create them.
- Feature branches follow the naming convention: `feature/{feature_id}`.
- Task branches continue to follow: `feature/{feature_id}-T{n}`.
- All existing CLAUDE.md branch rules apply within the feature branch scope.
- The feature reviewer agent must not mutate task YAMLs for tasks it does not own.
- The feature branch PR (feature → base) is opened by the orchestrator; the reviewer agent monitors it but does not create it.

## Chosen Design

One new daemon, activated after the orchestrator transitions a feature to `in_handoff`:

**Feature reviewer daemon** (new):
- Polls all features in `in_handoff` status.
- On each poll, checks for new commits on the base branch since the feature branch was created.
- Classifies impact (task-level vs feature-level) using file overlap + semantic analysis against `technical-design.md`.
- Acts: auto-rebase (task-level) or escalate with structured report (feature-level).

## Architecture

```
Orchestrator (from autonomous-task-orchestrator)
  │
  └── on all tasks done: generates handoff doc, opens feature PR, sets in_handoff

Feature Reviewer Daemon (this feature)
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

### Feature Reviewer Agent

**Poll loop (every 10 minutes):**
1. Read all `status.yaml` files — collect features with `feature_status: in_handoff`.
2. For each, resolve `feature_branch`, `feature_branch_base_sha`, and base branch from `status.yaml`.
3. Call GitHub API: `GET /repos/{owner}/{repo}/compare/{base_branch}...{feature_branch}` reversed — get commits on base branch not yet in feature branch since `feature_branch_base_sha`.
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
Generate structured report (see product spec format). Send to Slack webhook. Do not rebase. Write `drift_detected: true` and `drift_reason` into `status.yaml` on the feature branch. Wait for human to resolve before next poll cycle.

### status.yaml additions

Drift fields are written by this feature's daemon. The `feature_branch`, `feature_branch_base_sha`, and `handoff_pr_url` fields are written by the orchestrator and read (never overwritten) by this daemon.

```yaml
drift_detected: false
drift_reason: null
```

## Dependency Analysis

- **Depends on `autonomous-task-orchestrator`**: the reviewer daemon only activates on features the orchestrator has moved to `in_handoff`. Feature branch creation, task PR routing, handoff document generation, and feature PR opening are all owned by the orchestrator.
- **GitHub API**: compare endpoint for drift detection. Uses existing `GITHUB_TOKEN`.
- **Claude API**: semantic analysis call. Uses existing `ANTHROPIC_API_KEY`.
- **Slack webhook**: escalation. Uses `SLACK_WEBHOOK_URL`.
- **Management repo write access**: `status.yaml` drift field updates. Uses existing SSH key.

## Parallelization / Blocking Analysis

- Hard dependency on `autonomous-task-orchestrator` — the reviewer daemon cannot be tested end-to-end until the orchestrator is producing `in_handoff` features.
- Within this feature: classification logic, auto-rebase path, and escalation path are independent code paths and can be developed in parallel. Integration testing requires the orchestrator to be in place.
