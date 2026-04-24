# Task Breakdown — agent-runtime-pr-merge

Feature status: `in_tdd` | Tasks stage: `draft` | Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Extend PR poller + implement merge-completion handler | — |
| T2 | 2 | Documentation update | T1 |

---

## T1 — Extend PR poller + implement merge-completion handler

### Description

This task closes the gap identified in the technical design: when a human merges an implementation PR, the runtime currently has no mechanism to detect the merge and close out the task. Three files change in the `workflow` repo:

1. **`src/poll/check-in-review-prs.ts`** — Add `merged: Boolean!` to the GraphQL query and expose `merged: boolean` on `PrStatusResult`. The query already fetches `isDraft`, `mergeable`, and `reviewThreads`; `merged` is an additive field. `GitHubGraphQLPrData` gains `merged: boolean`. The parse block maps `pr.merged` to the result.

2. **`src/poll/handle-merged-prs.ts`** (new file) — The merge-completion handler. Modelled on `auto-rebase.ts`. Iterates `prResults` filtered to `merged: true`, reads the live task state from the feature branch via `tryReadTaskFromBranch`, guards against already-`done` / already-`pr.status:"merged"` tasks (idempotency), checks out and syncs the feature branch, updates the task YAML (`status: done`, `pr.status: "merged"`, log entry), commits + pushes, then calls `PUT /repos/{owner}/{repo}/pulls/{n}/merge` via `curlJson` to merge the workspace PR. Push rejections and workspace PR merge API errors are logged and skipped (non-fatal).

3. **`src/main.ts`** — Wire the new handler into `runOneCycle` after the existing `handleDraftReviews` block. Uses the already-present `parseManagementRepoCoords` helper to supply `mgmtRepoOwner` / `mgmtRepoName`.

The `done` log entry sets `by:` to `GIT_AUTHOR_EMAIL` and `note:` to `"Implementation PR merged — automated close-out by pr-merge loop."`. Merging the implementation PR is the human approval signal; no separate human log entry is required for this path.

After marking the task `done`, the handler applies the **auto-ready rule**: it scans all other task YAMLs in the same feature, finds any whose `depends_on` list is now fully satisfied, transitions them `todo → ready`, and appends a `ready` log entry to each. All YAML changes (completing task + newly-ready tasks) land in a single commit.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Add `merged: boolean` to `GitHubGraphQLPrData` interface
- [ ] Add `merged` field to `PR_STATUS_QUERY` GraphQL string
- [ ] Parse `pr.merged` and populate `PrStatusResult.merged`
- [ ] Create `src/poll/handle-merged-prs.ts` with `HandleMergedPrsOptions` interface and `handleMergedPrs` function
- [ ] Implement idempotency guard: skip if `task.status !== "in_review"` (covers done, cancelled, etc.) — `pr.status` is not read, it is write-only
- [ ] Implement branch checkout + sync (fetch, checkout, pull)
- [ ] Implement task YAML update: `status: done`, `pr.status: "merged"`, log entry
- [ ] Implement auto-ready rule: scan sibling task YAMLs, transition `todo → ready` for any whose `depends_on` is fully satisfied, append `ready` log entry to each
- [ ] Stage completing task YAML + any newly-ready task YAMLs in a single commit
- [ ] Implement commit + push with rebase-and-resolve on rejection: fetch + rebase; if clean retry push; if conflicted spawn Claude to resolve YAML conflict markers (keep local `done`/`ready` status, merge log arrays); if resolve fails emit `pr_merge_done_blocked` and stop
- [ ] Implement workspace PR merge via `PUT .../pulls/{n}/merge` REST call
- [ ] Handle `workspace_pr: null` case — emit warning, skip merge step, still mark done
- [ ] Wire `handleMergedPrs` call in `main.ts` after `handleDraftReviews` block
- [ ] Verify existing unit tests still pass; add unit tests for extended parser and new handler

---

## T2 — Documentation update

### Description

Update operator-facing docs in the `workflow` repo to describe the automated merge close-out behaviour introduced by T1. Two files:

1. **`agent-runtime/docs/OPERATOR-GUIDE.md`** — Add a section describing the PR merge loop: what it does, when it runs (tied to `pr_poll_interval_seconds`), what env vars it needs (`GITHUB_TOKEN` already required), and what happens when `workspace_pr` is null or the merge API call fails.

2. **`agent-runtime/DOCKER.md`** — Add a note under the `GITHUB_TOKEN` entry that it also enables automatic workspace PR merging when an implementation PR is merged.

No code changes. Docs must accurately describe T1's implemented behaviour — write these after T1 is merged so there is no risk of docs describing planned rather than actual behaviour.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Add "Automated PR merge close-out" section to `OPERATOR-GUIDE.md`
- [ ] Note `GITHUB_TOKEN` scope in `DOCKER.md` includes workspace PR auto-merge
- [ ] Verify `pr_poll_interval_seconds` is referenced correctly (controls merge check frequency)
