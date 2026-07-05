# Product Specification

## Feature
- Feature ID: `m3-agent-review-pr-skill`
- Title: Agent Chat PR Review — bring `/review-pr` rigor into M3 Agent Chat

## Background

The orchestrator/executor runtime has a skill, `project-workspace/.claude/skills/review-pr/`,
that runs whenever a task moves to `in_review`. It fetches the PR diff via the GitHub API,
waits for CI to resolve, evaluates the diff against a shared severity-tagged rubric
(`references/review_criteria.md`), posts a structured GitHub review (`APPROVE` /
`REQUEST_CHANGES`, with inline comments), and writes `result.json` so the orchestrator can
route task state (`passed` / `change_requested` / `escalate`).

Separately, M3 Agent Chat (`m3-agent-chat` → `m3-agent-chat-v4`) is a real-time chat surface
in `digital-factory-ui` where workspace members collaborate with one resident Hermes agent in
feature threads, workspace-level team threads, and channels. The agent only acts on an explicit
`@agent` mention (or a bare message inside a feature thread, v3 back-compat) — it never
self-dispatches (`m3-agent-chat-v4/technical-design.md` §3.5, §4.2).

Hermes agent bundles a subset of `project-workspace/.claude/skills/*` into its own skill index
(`hermes-agent/plugins/skills/index.py`) so the chat agent can pull skill guidance into context
via a `load_skill` tool. By design, this index **excludes mutation and execution skills** —
skills that need a bash/git environment the chat gateway does not have. `review-pr` and
`respond-to-review` are both absent from the bundled `workflow_skills/` set for this reason.

This bundling is not optional plumbing — it is the *only* path available. The hermes-agent chat
runtime is a separate deployment from the management repo (`project-workspace`) and has no
filesystem access to it: it cannot open `.claude/skills/review-pr/references/review_criteria.md`
at call time the way a project-workspace-local Claude Code session can. Anything the chat tool
needs from that skill — most importantly the `review_criteria.md` rubric text this feature reuses
(G2) — has to be **injected into hermes-agent's own bundle** (mirrored into
`hermes-agent/plugins/skills/...` at build/sync time, the same mechanism already used for the
rest of `workflow_skills/`), not read live from the workspace repo. This is a hard constraint,
not a choice between two equally-viable options — see OQ4.

Because live access isn't an option, this spec does not just point at the source skill by
path — the **Appendix** at the end of this document contains a verbatim snapshot of both
`SKILL.md` and `review_criteria.md` as of this spec's authoring. Technical design and
implementation should copy from that snapshot (re-syncing against the live files first if time
has passed and the source may have changed), rather than assuming the implementer has a
project-workspace checkout on hand when building the hermes-agent side of this feature.

## Problem

### Asking the chat agent to review a PR today produces an unstructured, unverifiable answer

A user can type `@agent review this PR` in any thread today, but the agent has no dedicated
capability behind that request — it's a freeform LLM turn. There is no guarantee the agent
actually fetches the diff, no guarantee it checks CI status, no application of
`review_criteria.md`, and no GitHub review is posted. The response is whatever the model
improvises, with no severity-tagged findings and no artifact a reviewer can point to later.

### The rigorous version of this capability exists but is deliberately out of reach in chat

`/review-pr` already implements exactly the missing rigor — diff fetch, CI polling, rubric
evaluation, structured GitHub review posting, self-review-restriction handling — but it is
shaped as a bash/git execution skill for the orchestrator's autonomous executor environment.
It reads from and writes to task YAML (`result.json`, review-cycle counts) that only make
sense inside the orchestrator's task state machine. It cannot be dropped into chat unmodified.

### Chat has no GitHub context or credentials to hydrate a review from

The orchestrator's skill is handed a fully-resolved context block (`Task ID`, `Impl repo`,
`Branch`, `PR URL`, `Result path`, review-cycle counters) and a `GITHUB_TOKEN` the executor
environment already provides. Chat sessions track a `feature_id` but have no concept of
"task" or "PR," and no confirmed GitHub API credential path exists in the hermes-agent chat
runtime today (`hermes-agent/plugins/tools/*` has no `GITHUB_TOKEN` plumbing). Without this,
even a well-scoped chat tool has nothing to authenticate a GitHub review post with.

### Net effect

Teams that want a rigorous PR review outside the orchestrator's own task pipeline (e.g. a
human asking the chat agent to sanity-check a PR before merging, or reviewing work that isn't
tracked as an orchestrator task) have no equivalent to `/review-pr` available to them. They
either wait for the orchestrator's own review cycle or fall back to a fully manual review.

## Goals

- **G1 — A chat-invocable PR review tool.** The resident agent gains a tool (invoked via
  `@agent` natural-language request, and/or the existing `/` slash-command picker in
  `digital-factory-ui`) that accepts a GitHub PR URL and performs a structured review.
- **G2 — Same rubric, not a reimplementation.** The tool evaluates the diff against the same
  severity-tagged criteria as `references/review_criteria.md` (Correctness → Security →
  Performance → Design → Style, 🔴/🟡/🟢 markers). Since the chat runtime cannot read
  `project-workspace/.claude/skills/*` at call time (see Background), this means a mirrored
  copy of `review_criteria.md` is injected into hermes-agent's own bundle
  (`hermes-agent/plugins/skills/...`) and kept in sync with the source — not a live fetch, and
  not a second, independently-maintained copy that can drift.
- **G3 — Real GitHub review artifact.** The tool fetches the actual PR diff and CI check-run
  status via the GitHub REST API, and posts a real GitHub review (issue comment with full
  narrative, plus an `APPROVE` / `REQUEST_CHANGES` review event with inline comments where the
  self-review restriction allows it) — the same two-call pattern and 422 self-review handling
  as the orchestrator skill.
- **G4 — Chat-readable summary.** After posting, the agent replies in the thread with the
  verdict and a severity-tagged findings summary, plus a link to the posted GitHub review (or
  the comment URL when the review event was skipped due to self-review).
- **G5 — Decoupled from orchestrator task state.** The chat tool does not read or write task
  YAML, does not write `result.json`, and is not gated by review-cycle counters — those are
  orchestrator-only concepts. A chat-invoked review is a single on-demand action reported back
  to the human, who decides what happens next.
- **G6 — GitHub credentials resolved for the chat runtime.** A credential path is established
  so hermes-agent's tool execution can authenticate GitHub REST calls (exact mechanism —
  shared token, workspace-scoped secret, etc. — resolved in technical design).
- **G7 — Read-only GitHub context tools, usable independently of a full review.** The agent
  knows how to use the GitHub token for read-only lookups beyond the single review flow, as
  standalone primitives it can call whenever a thread needs GitHub context. The full review
  tool (G1–G4) is built on top of these primitives — it does not have its own separate,
  narrower way of talking to GitHub.

  **PR-level**
  - Read a PR's diff/patch.
  - Read a PR's changed-files list (paths, additions/deletions, status — added/modified/renamed/removed).
  - Read PR metadata: title, description/body, author, base/head branch and SHA, state
    (open/closed/merged), draft status, labels, requested reviewers, linked issues.
  - Read a PR's existing comments and review threads (issue comments + inline review comments),
    so the agent can see prior discussion before adding its own.
  - Read the PR's review history — who reviewed, their verdict (`APPROVE` /
    `REQUEST_CHANGES` / `COMMENT`), and when — not just the latest state.
  - Read CI / status-check results for the PR's head commit (check-run names, conclusions,
    and — where available — links to logs), independent of the review flow's own CI-polling step.
  - List open (or filtered) PRs for a repo or branch, so the agent can answer "what PRs are
    open for this feature" without the user supplying a URL.

  **Commit-level**
  - Read commit history on a branch or for a PR's set of commits (messages, authors, SHAs,
    timestamps).
  - Read an individual commit's diff and metadata.
  - Compare two refs/branches/commits (ahead/behind counts, the diff between them).

  **Repo/file-level**
  - Read a file's full content at a given ref/commit — not just the diff hunk. This matters
    beyond convenience: `review_criteria.md` already requires that findings about missing or
    incorrect behavior in *unmodified* code be verified by reading that code directly, never
    inferred from its absence in the diff. A chat tool that can only see diff hunks cannot
    satisfy that rule; full-file-at-ref read access is required for the review tool to meet the
    same bar the orchestrator's skill does.
  - Read basic repo metadata needed to resolve a PR URL or branch reference (default branch,
    repo visibility) when the agent needs to disambiguate what was given.

  These are all read-only — no writes, no review posting — so the agent can answer questions
  like "what changed in this PR," "has anyone already commented," "why did CI fail," or "what
  does this function currently do" without triggering a full review-and-post flow.

## Non-goals

- **NG1 — No changes to the orchestrator's `/review-pr` skill.** It continues to run unmodified
  for orchestrator-dispatched task reviews, including its `result.json` contract and
  review-cycle escalation logic.
- **NG2 — No task/PR concept added to the chat session schema.** Beyond passing a PR URL into
  the tool call, this feature does not add task-state tracking to chat sessions.
- **NG3 — No autonomous/unprompted reviews.** Consistent with v4's triggered-only guardrail,
  the agent reviews a PR only on an explicit request in the current turn — never on its own.
- **NG4 — No review-cycle retry or confidence-threshold escalation.** `MAX_REVIEW_CYCLES` and
  confidence-based escalation are orchestrator concepts tied to automated task retries. A
  chat-invoked review always attempts once and reports the outcome; the human decides whether
  to ask for another pass.
- **NG5 — No PR merging from chat.** The orchestrator's auto-merge-on-`APPROVE` step (Step 7 of
  `/review-pr`) is out of scope. A chat-invoked review stops after posting the review; merging
  remains a human action (or the orchestrator's own flow, for orchestrator-tracked tasks).

## User Flows

### Reviewing a PR from a feature thread

1. A workspace member in a feature thread pastes a GitHub PR link and asks `@agent review this`.
2. The agent fetches the diff and CI status, evaluates against the shared rubric, and posts a
   GitHub review (comment + review event, or comment-only if self-review applies).
3. The agent replies in the thread with the verdict and findings (🔴/🟡/🟢, file/line
   references) and a link to the posted review.

### CI still resolving when the review is requested

1. A member asks for a review immediately after opening a PR, before CI has finished.
2. The agent polls check-runs for a bounded window. If CI resolves within that window, the
   review proceeds normally. If not, the agent reports back that CI is still pending and asks
   the member to retry once it resolves — it does not block the chat turn indefinitely.

### Self-review restriction

1. A member asks the agent to review a PR that was opened under the same GitHub identity the
   review tool authenticates as.
2. GitHub returns `422` on the review-event POST. The agent's issue-comment narrative (Step 6a
   equivalent) still succeeds and is the authoritative record. The agent reports this plainly
   in the thread: findings summary + comment link, with a note that the formal review event
   could not be posted due to the self-review restriction.

## Acceptance Criteria

- A member can trigger a structured PR review from chat via `@agent` (natural language) with a
  PR URL, or via the slash-command picker.
- The review evaluates the diff against the same rubric content as
  `.claude/skills/review-pr/references/review_criteria.md` — no separate, divergent rubric.
- A real GitHub review is posted and independently verifiable at the returned URL (or a
  comment URL, with a clear note, when self-review restrictions apply).
- The chat thread shows a severity-tagged findings summary after the review completes.
- The agent can answer read-only GitHub questions (PR diff, changed files, PR metadata,
  existing comments/review history, CI status, open-PR listing, commit history, ref
  comparison, full file content at a given ref) as standalone requests, without triggering a
  full review-and-post flow.
- When a review finding concerns unmodified/existing code, the agent reads that code directly
  via the full-file-at-ref tool rather than inferring behavior from its absence in the diff —
  matching the rule already enforced in `review_criteria.md`.
- No task YAML or `result.json` artifacts are created or modified by this feature.
- The feature does not merge PRs.
- Lint, type-check, and the full test suites of all touched repos pass before any PR.

## Scope

### In scope

**hermes-agent**
- New tool implementing the review flow: diff fetch, CI check-run polling (bounded), rubric
  evaluation, GitHub review posting (two-call pattern + self-review handling), chat-message
  summary.
- New read-only GitHub context tools (G7), callable standalone or as building blocks for the
  review flow: PR diff/changed-files/metadata/comments/review-history/CI-status, open-PR
  listing, branch/PR commit history and individual commit diffs, ref comparison, and
  full-file-content-at-ref reads.
- Reuse of `review_criteria.md` as the rubric source of truth — injected into hermes-agent's
  own bundle as a mirrored copy (the chat runtime cannot read `project-workspace/.claude/skills/*`
  live, per Background), loaded the same way other bundled reference docs are, and kept in
  sync with the source rather than reimplemented as separate prose (sync mechanism: OQ4).
- GitHub credential resolution for tool execution, covering both the read-only lookups and the
  review-posting write call (mechanism TBD in technical design).

**digital-factory-ui**
- Optional: a `/review-pr`-style entry in the existing slash-command picker
  (`slash-command-picker.tsx` / `services/hermes-agent/tools.ts`) as an alternate invocation
  path alongside natural-language `@agent` requests.

### Out of scope

- Any modification to `project-workspace/.claude/skills/review-pr/` or its `result.json`
  contract.
- Task lifecycle state, review-cycle counters, or confidence-threshold escalation.
- Auto-merge of the reviewed PR.
- Orchestrator dispatch logic (see `reviewer-dispatch-hardening`, out of scope here).

## Open Questions

- **OQ1 — GitHub credential path and scope for hermes-agent.** No existing hermes-agent tool
  authenticates GitHub REST calls today. Resolve in technical design: a shared token passed
  through the executor-style env pattern, a workspace-scoped secret, or something else. The
  token needs at least read scope (contents, pull-requests, issues) for the G7 read-only
  tools, plus write scope (pull-requests, issues) for posting reviews — confirm whether one
  token covers both or whether reads and the review-post step should use different credentials.
- **OQ2 — Posting identity.** Should the chat-invoked review post under a dedicated reviewer
  account (mirroring the orchestrator's bot-identity pattern), or under the credential
  resolved by OQ1 regardless of whose account that is? Affects how often the self-review path
  is hit.
- **OQ3 — Which chat containers are in scope for v1.** Feature threads are the clear MVP
  target since PRs are inherently feature/task-adjacent. Whether workspace-level team threads
  and channels also get this tool in v1, or it's deferred, needs a decision.
- **OQ4 — Rubric sync mechanism, not distribution choice.** The chat runtime's lack of
  filesystem access to `project-workspace` (see Background) rules out a live fetch — the
  mirrored-bundle approach is not optional. What's still open is *how* the mirror stays in
  sync: a manual copy step as part of releasing this feature (matching how `workflow_skills/`
  appears to be mirrored today, per the research behind this spec), an automated sync job/CI
  check that fails when `review_criteria.md` and its hermes-agent mirror diverge, or something
  else. Resolve the sync mechanism in technical design.
- **OQ5 — CI-poll timeout for a synchronous chat turn.** The orchestrator skill polls CI for up
  to 10 minutes. A chat turn is latency-sensitive and the user is actively waiting — resolve
  whether to shorten the bound, or have the agent respond immediately and let the user
  re-trigger once CI is green.

## References

- Orchestrator skill this feature mirrors:
  `.claude/skills/review-pr/SKILL.md`, `.claude/skills/review-pr/references/review_criteria.md`
- Chat surface being extended: `docs/features/m3-agent-chat-v4/product-spec.md`,
  `technical-design.md` (triggered-only dispatch, thread containers)
- Hermes skill bundling mechanism: `hermes-agent/plugins/skills/index.py`,
  `hermes-agent/plugins/tools/skills.py`
- Existing chat tool-invocation surface: `digital-factory-ui/src/components/agent-chat/slash-command-picker.tsx`,
  `digital-factory-ui/src/services/hermes-agent/tools.ts`, `hermes-agent/src/api/routers/tools.py`
- Adjacent features (scope does not overlap):
  - `agent-rag-pr-index` — indexes merged PR titles/descriptions into RAG; retrieval only, not review.
  - `agent-pr-response` — orchestrator-side follow-up on an already-open PR after `in_review`.
  - `feature-branch-pr-review-gate` — reviewer pass for the cumulative feature-branch PR.
  - `reviewer-dispatch-hardening` — orchestrator dispatch-decision internals.
  - Touched repos for this feature: `hermes-agent` (review tool, GitHub API calls),
    `digital-factory-ui` (optional slash-command entry).

## Appendix — source skill content (verbatim, as of this spec's authoring)

The chat runtime cannot read `project-workspace/.claude/skills/*` live (see Background). These
are captured here in full so technical design and implementation have the exact source content
to mirror into hermes-agent's bundle, without depending on live repo access at build time. If
the source skill changes after this spec is written, re-sync against the live files at
`.claude/skills/review-pr/SKILL.md` and `.claude/skills/review-pr/references/review_criteria.md`
before implementation — this appendix is a snapshot, not the source of truth going forward.

### `.claude/skills/review-pr/SKILL.md`

````markdown
---
name: review-pr
description: >-
  Autonomous PR reviewer that evaluates implementation quality against the task
  spec and technical design, posts a GitHub APPROVE or REQUEST_CHANGES review,
  and writes a structured result.json for the orchestrator to route.
---

## GitNexus code lookup

If `mcp__gitnexus__*` tools are in your tool list, use them for structural lookups
(symbol definitions, callers, impact analysis) before falling back to grep or file
reads. If the MCP is unavailable or returns no results, fall back to grep/Read.

---

# Review PR

Evaluates a pull request against the task specification and technical design,
posts a GitHub review (APPROVE or REQUEST_CHANGES), and writes `result.json`
with the reviewer verdict for the orchestrator to route.

## Context

All required values are provided in the agent context under **## Your claimed task**:

| Key | Description |
|---|---|
| `Workspace root` | Absolute path to the management (workspace) repo |
| `Feature` | Feature ID (e.g. `autonomous-task-orchestrator`) |
| `Task ID` | Task ID (e.g. `T3`) |
| `Impl repo` | Implementation repo ID |
| `Repo root` | Absolute path to the implementation repo |
| `Branch` | Feature branch name (e.g. `feature/autonomous-task-orchestrator-T3`) |
| `PR URL` | GitHub PR URL (`https://github.com/{owner}/{repo}/pull/{number}`) |
| `Result path` | Absolute path to write `result.json` |
| `Max review cycles` | Maximum number of review cycles before escalating |
| `Review cycle count` | Number of `in_review` log entries already on this task |

The `GITHUB_TOKEN` environment variable is set for all GitHub API calls.

---

## Cycle limit check — run first

Before doing anything else, check whether the review cycle limit has been reached:

1. Read `MAX_REVIEW_CYCLES` from the environment (default: `3`).
2. Count `in_review` log entries in the task YAML at
   `<Workspace root>/docs/features/<Feature>/tasks/<Task ID>.yaml`.
3. If the count is already ≥ `MAX_REVIEW_CYCLES`:
   - Write `result.json` immediately with `terminal_status: "escalate"`:
     ```json
     {
       "terminal_status": "escalate",
       "verdict": "escalate",
       "confidence": 1.0,
       "notes": "Review cycle limit reached. Human review required."
     }
     ```
   - Stop. Do not post a GitHub review. Do not read the PR diff.

---

## Before reviewing

Read the following documents in order to understand the full context:

1. `<Workspace root>/docs/features/<Feature>/product-spec.md` — original requirements
2. `<Workspace root>/docs/features/<Feature>/technical-design.md` — architecture decisions
3. `<Workspace root>/docs/features/<Feature>/tasks.md` under `## <Task ID> — <title>` — specific scope, subtasks, and acceptance criteria

Every finding must be grounded in these documents. Do not request changes that
contradict the approved spec.

---

## Execution steps

### Step 1 — Parse the PR URL

Extract `owner`, `repo`, and `pull_number` from the `PR URL`:

```
https://github.com/{owner}/{repo}/pull/{pull_number}
```

### Step 2 — Fetch the PR diff

```bash
curl -s \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3.diff" \
  "https://api.github.com/repos/{owner}/{repo}/pulls/{pull_number}"
```

Read the full diff. Note every file changed and every line added or removed.

### Step 3 — Wait for CI to resolve

Poll CI check-runs until all checks reach a terminal state (success, failure,
cancelled, or skipped). Maximum wait: 10 minutes; poll every 30 seconds.

```bash
curl -s \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  "https://api.github.com/repos/{owner}/{repo}/commits/{head_sha}/check-runs"
```

If any check-run has `conclusion: failure` or `conclusion: cancelled`:
- CI failed. Record this as a 🔴 finding with severity `blocker`.
- You do not need to wait for remaining checks.

If all check-runs have `conclusion: success` (or there are no check-runs):
- CI passed. Continue to rubric evaluation.

If the 10-minute timeout expires before all checks resolve:
- Treat as CI failure. Record as a 🔴 finding: "CI timed out — checks still pending."

### Step 4 — Evaluate the PR against the rubric

Apply every criterion in
`<Skill dir>/references/review_criteria.md` to the diff.

For each finding, classify severity:
- 🔴 **Blocker** — correctness or security issue; blocks merge
- 🟡 **Important** — performance or design issue; should fix
- 🟢 **Nit / suggestion** — style or minor improvement; does not block

**Before recording any finding about missing or incorrect behaviour in existing (unmodified) code:**
Read that code directly — do not infer absence from non-appearance in the diff. "Not in the diff"
means the file was not changed, not that the behaviour does not exist. If the relevant function or
module is in the implementation repo but you have not read it, read it before filing a 🔴 or 🟡.
If you cannot read it (repo not available), downgrade to 🟢 with a note ("verify that X handles Y")
rather than asserting a blocker.

Record findings with:
- File path and line reference (from the diff)
- Criterion from the rubric that was violated
- Clear description of the problem
- Concrete suggestion for how to fix it

### Step 5 — Apply the decision table

| Condition | Decision | `terminal_status` |
|---|---|---|
| Cycle count ≥ `MAX_REVIEW_CYCLES` | Escalate immediately | `escalate` |
| CI failed | REQUEST_CHANGES | `change_requested` |
| Any 🔴 finding | REQUEST_CHANGES | `change_requested` |
| Any 🟡 finding | REQUEST_CHANGES | `change_requested` |
| Only 🟢 findings or no findings | APPROVE | `passed` |

### Step 6 — Post the GitHub review (two-call pattern)

The review post is split into two independent API calls. **Both calls must be attempted in order**, even if the first one returns an unexpected error.

#### Step 6a — Post comment (always execute)

Post the full review narrative as a regular issue comment. This endpoint is **not** subject to the GitHub self-review restriction.

```bash
curl -s -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/{owner}/{repo}/issues/{pull_number}/comments" \
  -d '{
    "body": "<full review narrative: verdict, all findings with severity markers, inline references>"
  }'
```

This call must always succeed. If it fails (non-422 error), treat as a fatal error: log the response and write an `escalate` result. Do not suppress errors from this step.

Capture the `html_url` from the response body — use it as `review_url` in result.json if Step 6b is skipped.

#### Step 6b — Post review event (attempt after 6a; skip on 422)

Attempt to post the formal review event. Include inline comments for findings here so reviewers can see them in the GitHub diff view.

For **APPROVE**:
```bash
curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/{owner}/{repo}/pulls/{pull_number}/reviews" \
  -d '{
    "event": "APPROVE",
    "body": "<brief summary>",
    "comments": [<inline 🟢 nit comments if any>]
  }'
```

For **REQUEST_CHANGES**:
```bash
curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/{owner}/{repo}/pulls/{pull_number}/reviews" \
  -d '{
    "event": "REQUEST_CHANGES",
    "body": "<brief summary of all findings>",
    "comments": [<inline comments for each 🔴/🟡 finding>]
  }'
```

Inline comment format:
```json
{
  "path": "<file path>",
  "line": <line number in the diff>,
  "body": "🔴 **Blocker** — <description>\n\n<concrete suggestion>"
}
```

**Self-review handling**: Read the HTTP status code from the response:
- **HTTP 201** — review posted. Capture the `url` from the response body; record it in `result.json` as `review_url`.
- **HTTP 422** — GitHub self-review restriction. Emit `reviewer_self_review_skipped` to stdout:
  ```
  reviewer_self_review_skipped task_id=<task_id> feature_id=<feature_id> pr_number=<pull_number>
  ```
  Set `review_url` to `null` and `self_review_skipped: true` in `result.json`. Do **not** fail the executor — the comment in step 6a is the authoritative narrative. Proceed to Step 7.
- **Any other error** — fatal. Log the response body to stderr and write an `escalate` result with the error details. Stop.

### Step 7 — Merge the PR (APPROVE path only)

If the decision is **REQUEST_CHANGES** or **escalate**, skip this step entirely.

Step 7 is **best-effort**: success is not required for the task to eventually be
marked `done`. The orchestrator's in_review PR poll watches the implementation
PR on GitHub; whenever it sees `merged: true` (whether merged by this step or by
a human later), `handleMergedPrs` writes `status: done` and runs the auto-ready
cascade.

**Check whether the task requires human merge.** Re-read the task YAML at
`<Workspace root>/docs/features/<Feature>/tasks/<Task ID>.yaml` and check the value
of `execution.requires_human_review`. If `true`, skip the merge call entirely — the
APPROVE review has already been posted; the human will merge the PR. Proceed to Step 8.

Otherwise, squash-merge the implementation PR via the GitHub REST API:

```bash
curl -s -w "\n%{http_code}" -X PUT \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/{owner}/{repo}/pulls/{pull_number}/merge" \
  -d '{"merge_method": "squash"}'
```

Read the HTTP status code:
- **HTTP 200** — merged successfully. Continue to Step 8.
- **HTTP 405** — PR already merged, or merge not allowed (e.g. branch protection
  requires a human approval). Continue to Step 8 — if the PR is open, the human
  will merge and the poll will catch it.
- **HTTP 409** — merge conflict. The branch needs to be rebased before it can merge. Write
  `terminal_status: "change_requested"` to result.json immediately and stop:
  ```json
  {
    "terminal_status": "change_requested",
    "verdict": "change_requested",
    "confidence": 1.0,
    "notes": "Merge conflict (HTTP 409) — branch must be rebased onto the base branch before merging."
  }
  ```
  Do not post a REQUEST_CHANGES review event for this case — the conflict is a branch
  management issue, not a code quality issue. The fix agent will rebase and re-push.
- **Any other error** — log the response to stdout. Continue to Step 8 — do not
  escalate for merge failure alone.

### Step 8 — Compute confidence

Assign a confidence score (0.0–1.0) reflecting how certain you are in the verdict:

- `1.0` — clear CI failure or obvious correctness bug with no ambiguity
- `0.8–0.9` — strong finding with clear rubric match
- `0.6–0.7` — judgment call (design tradeoff, ambiguous spec wording)
- `< 0.6` — escalate: confidence too low for autonomous decision

If confidence < `CONFIDENCE_THRESHOLD` (default: `0.80`), override the decision to
`terminal_status: "escalate"` regardless of the rubric outcome.

### Step 9 — Write result.json

Write the result file to the path provided in the agent context (`Result path`):

**On APPROVE / passed (review event posted):**
```json
{
  "terminal_status": "passed",
  "verdict": "passed",
  "confidence": 0.92,
  "notes": "All subtasks implemented. CI passed. No 🔴/🟡 findings.",
  "review_url": "https://github.com/{owner}/{repo}/pulls/{pull_number}/reviews/{review_id}"
}
```

**On APPROVE / passed (self-review restriction — review event skipped):**
```json
{
  "terminal_status": "passed",
  "verdict": "passed",
  "confidence": 0.92,
  "notes": "All subtasks implemented. CI passed. No 🔴/🟡 findings.",
  "review_url": "https://github.com/{owner}/{repo}/issues/{pull_number}#issuecomment-{id}",
  "self_review_skipped": true
}
```

**On REQUEST_CHANGES / change_requested (review event posted):**
```json
{
  "terminal_status": "change_requested",
  "verdict": "change_requested",
  "confidence": 0.88,
  "notes": "🔴 Missing null check in processTask() (src/poll/reap-loop.ts:47). 🟡 N+1 git-fetch inside loop (main.ts:203).",
  "review_url": "https://github.com/{owner}/{repo}/pulls/{pull_number}/reviews/{review_id}"
}
```

**On REQUEST_CHANGES / change_requested (self-review restriction — review event skipped):**
```json
{
  "terminal_status": "change_requested",
  "verdict": "change_requested",
  "confidence": 0.88,
  "notes": "🔴 Missing null check in processTask() (src/poll/reap-loop.ts:47).",
  "review_url": "https://github.com/{owner}/{repo}/issues/{pull_number}#issuecomment-{id}",
  "self_review_skipped": true
}
```

**On escalation:**
```json
{
  "terminal_status": "escalate",
  "verdict": "escalate",
  "confidence": 0.55,
  "notes": "Confidence below threshold. Review cycle limit or ambiguous spec — human review required."
}
```

---

## result.json schema

```json
{
  "terminal_status":     "passed" | "change_requested" | "escalate",
  "verdict":             "passed" | "change_requested" | "escalate",
  "confidence":          0.0 to 1.0,
  "notes":               "<one-line summary of findings>",
  "review_url":          "<GitHub review URL from Step 6b when posted; Step 6a comment URL when Step 6b returned 422; omit on escalate>",
  "self_review_skipped": true | false  // true when GitHub returned 422 on the review event POST
}
```

`result.json` **must** be written as the final step in every code path, including
on error. If you cannot complete the review, write:
```json
{
  "terminal_status": "escalate",
  "verdict": "escalate",
  "confidence": 0.0,
  "notes": "<reason for failure>"
}
```

---

## Error handling

| Situation | Action |
|---|---|
| PR diff fetch fails | Write `escalate` result with reason; stop |
| CI check-run API fails | Treat as CI timed out (🔴 finding); continue to review |
| Step 6a comment POST fails (non-422) | Write `escalate` result with reason; stop |
| Step 6b review POST returns 422 (self-review) | Emit `reviewer_self_review_skipped` to stdout; set `self_review_skipped: true`; continue without `review_url` |
| Step 6b review POST fails (other error) | Fatal — write `escalate` result with error details; stop |
| Step 7 merge returns 405 | PR already merged or branch protection — skip, continue |
| Step 7 merge returns 409 | Merge conflict — write `change_requested` result and stop; fix agent will rebase |
| Step 7 merge fails (other) | Log response to stdout; skip; continue — do not escalate for merge failure |
| Task YAML unreadable | Write `escalate` result; stop |
| Any `127` command not found | Write `escalate` result immediately; stop |

---

## Hard stop rule — missing tools

If any shell command exits with code 127, **first diagnose which command was not found**:

- Read the stderr/stdout output to identify the missing command name.
- If the **top-level tool** (e.g. `npm`, `pnpm`, `node`, `yarn`, `go`, `python`) is the one not found — the system tool is missing. Stop immediately and write:
  ```json
  {"terminal_status": "escalate", "verdict": "escalate", "confidence": 0.0, "notes": "missing_tool: <tool> command not found"}
  ```
- If the top-level tool **ran successfully** but a sub-command or binary it invoked was not found (e.g. `sh: vitest: not found` inside `npm run test`) — this is a missing project dependency, not a missing system tool. Diagnose and recover:
  1. Check whether the project dependency directory exists (e.g. `node_modules` for JS, virtual env for Python).
  2. If absent, install it using the appropriate command detected from the project (lock-file detection: `pnpm-lock.yaml` → `pnpm install --frozen-lockfile`, `yarn.lock` → `yarn install --frozen-lockfile`, `package-lock.json` → `npm ci`, `requirements.txt` → `pip install -r requirements.txt`, etc.).
  3. Re-run the original command once. If it exits 127 again, stop and escalate.

Do not attempt to install missing **system** tools or work around a missing top-level tool.
````

### `.claude/skills/review-pr/references/review_criteria.md`

````markdown
# PR Review Criteria

Criteria are applied in priority order. A finding in an earlier category supersedes
later categories in severity — a correctness bug outranks a style issue regardless
of how many style issues are present.

---

## Severity markers

| Marker | Severity | Reviewer action |
|---|---|---|
| 🔴 | Blocker — correctness or security | `REQUEST_CHANGES` — must fix before merge |
| 🟡 | Important — performance or design | `REQUEST_CHANGES` — should fix |
| 🟢 / 💡 | Nit / suggestion | Inline comment only; still `APPROVE` if no 🔴/🟡 |

The PR is approved if and only if there are **zero 🔴 or 🟡 findings**.

---

## 1. Correctness

*Priority 1 — highest weight.*

Check that the implementation produces the correct output for all inputs and
handles edge cases without crashing or producing wrong results.

| Check | Blocker? |
|---|---|
| Logic errors — incorrect algorithm, wrong formula, inverted condition | 🔴 |
| Off-by-one errors in loops, slice indices, pagination | 🔴 |
| Null / undefined dereference — accessing a field on a potentially-null value without guard | 🔴 |
| Missing error handling for an operation that can fail (network, FS, parse) | 🔴 |
| Race condition — shared mutable state accessed from concurrent code paths without synchronisation | 🔴 |
| Incorrect async flow — `await` missing, promise swallowed, unhandled rejection | 🔴 |
| Wrong data type passed to a function or stored in a field | 🔴 |
| Subtask listed in `tasks.md` not implemented or partially implemented | 🔴 |
| Test plan item from `tasks.md` not covered by a test | 🟡 |
| Edge case handled in tests but not in production code | 🔴 |
| Hardcoded value that should be configurable per the spec | 🟡 |

---

## 2. Security

*Priority 2.*

Check that the implementation does not introduce vulnerabilities.

| Check | Blocker? |
|---|---|
| Command injection — unsanitised user input passed to `exec`/`spawn`/`eval` | 🔴 |
| Path traversal — unsanitised input used in file path construction | 🔴 |
| SQL injection — dynamic query construction from user input | 🔴 |
| XSS — user input rendered in HTML without escaping | 🔴 |
| Hardcoded secret, API key, password, or token in source code | 🔴 |
| Secret logged at any log level | 🔴 |
| Auth / authz gap — an endpoint or operation that should require authentication does not check it | 🔴 |
| Missing input validation at system boundary (HTTP request, CLI arg, file read) | 🟡 |
| Overly permissive CORS, file permissions, or IAM policy | 🟡 |
| Dependency with known CVE introduced without justification | 🟡 |
| Sensitive data returned in API response when not needed | 🟡 |

---

## 3. Performance

*Priority 3.*

Check that the implementation does not introduce unacceptable latency or resource
usage for the expected workload described in the technical design.

| Check | Blocker? |
|---|---|
| N+1 query — a query is issued inside a loop when a single batched query could replace it | 🟡 |
| Synchronous / blocking I/O on the main event loop when async is available | 🟡 |
| O(n²) or worse algorithm where the technical design implies n can be large (> 1 000) | 🟡 |
| Loading an entire large file or dataset into memory when streaming would suffice | 🟡 |
| Missing index on a frequently-queried column (database schema changes) | 🟡 |
| Polling interval or retry loop with no back-off, leading to thundering-herd risk | 🟡 |
| Unbounded in-memory cache or queue with no eviction policy | 🟢 |

---

## 4. Design and architecture

*Priority 4.*

Check that the implementation matches the architectural decisions in the
technical design and follows existing codebase patterns.

| Check | Blocker? |
|---|---|
| Single responsibility violated — a module or function handles multiple unrelated concerns | 🟡 |
| DRY violation — logic duplicated across files when a shared utility already exists | 🟡 |
| Abstraction mismatch — implementation bypasses a port/adapter or breaks a layer boundary | 🟡 |
| New dependency added that duplicates an existing library already in `package.json` / `go.mod` | 🟡 |
| Configuration value embedded in application code instead of read from env / config | 🟡 |
| Wrong layer for a concern (e.g. business logic in a view, DB query in a controller) | 🟡 |
| Side-effects in a function declared as pure / no-side-effects | 🟡 |
| Missing interface or type definition that the tech design says should exist | 🟡 |
| Public API wider than the tech design specifies (extra exported symbols without justification) | 🟢 |
| Commented-out code left in without explanation | 🟢 |

---

## 5. Style and conventions

*Priority 5 — lowest weight.*

Check that the implementation follows the project's style and lint rules. These
findings are nits unless a linter failure is confirmed.

| Check | Blocker? |
|---|---|
| Linter / formatter rule violation (confirmed by running the project's lint command) | 🟡 |
| Naming convention violated — variable, function, type, or file named inconsistently with surrounding code | 🟢 |
| Unnecessary comment describing *what* the code does rather than *why* | 🟢 |
| Missing or misleading JSDoc / godoc / docstring where the project convention requires one | 🟢 |
| Import order or grouping inconsistent with the project's `eslint-plugin-import` / `goimports` config | 🟢 |
| Dead code — exported symbol or file never referenced outside the PR | 🟢 |
| Test file not co-located with its module when the project uses a co-location convention | 🟢 |
| TODO comment without a linked issue or task ID | 🟢 |

---

## Evaluation checklist

Before posting the GitHub review, verify every item below:

- [ ] All subtasks from `tasks.md` are implemented (Correctness)
- [ ] All test-plan items from `tasks.md` have a corresponding test (Correctness)
- [ ] Every finding about missing behaviour in unmodified code is verified by reading that code — never inferred from its absence in the diff
- [ ] CI check-runs have all reached a terminal state (Correctness)
- [ ] No secrets or hardcoded credentials (Security)
- [ ] No obvious injection or path-traversal surface (Security)
- [ ] No N+1 or blocking-I/O patterns (Performance)
- [ ] Implementation matches the architecture in `technical-design.md` (Design)
- [ ] No DRY violations against the existing codebase (Design)
- [ ] Linter passes (Style) — run the project's lint command to confirm
- [ ] Confidence score ≥ threshold; if not, escalate (Cycle limit)
````
