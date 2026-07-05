# Tasks — `m3-agent-review-pr-skill`

> Feature status: `in_tdd` — technical design approved 2026-07-05. Task stage: **draft** —
> awaiting human approval.
>
> Narrative (description + required skills + subtasks) lives here; machine-readable state
> (status, deps, branch, log, PR) lives per-task in `tasks/T<n>.yaml`. Agents mutate only the
> YAMLs.
>
> See `technical-design.md` §4 (Chosen Design), §6 (Parallelization diagram) and §7 (Repository
> Impact) for the design this breakdown implements. `D1` (GITHUB_TOKEN scope on implementation
> repos) was verified during design — no external dependency remains blocking these tasks.

## Index

| ID | Title | Repo | Depends On | Actor |
|----|-------|------|------------|-------|
| T1 | Read-only GitHub PR context tool + shared client | hermes-agent | — | agent |
| T2 | PR review posting tool (two-call pattern + self-review handling) | hermes-agent | T1 | agent |
| T3 | Rewrite bundled `review-pr` skill doc to the new tool-call sequence | hermes-agent | T1, T2 | agent |
| T4 | `ReviewCard` chat rendering (optional fast-follow) | digital-factory-ui | T2 | agent |

---

## T1 — Read-only GitHub PR context tool + shared client

### Description
Implements product-spec G7 and the fetch step of G1–G4, per `technical-design.md` §4. Add a new
`plugins/tools/github_pr_context.py` tool with an `action` enum (`diff | files | metadata |
comments | reviews | checks | commits | compare | file_at_ref | list_prs`), matching the existing
`action=`/`tool=`-enum convention used by `plugins/tools/gitnexus.py` and `plugins/tools/rag.py`.
Back it with new shared GitHub PR client functions that extend `plugins/document_repo.py`'s
`_headers()`/`_GITHUB_API_URL` pattern to implementation-repo PR endpoints (today's usage is
management-repo-only). `checks` implements the bounded CI-poll (§3e / OQ5): poll up to
`CHAT_REVIEW_CI_POLL_TIMEOUT_SECONDS` (default 60s, 15s interval) and return a `pending` status if
unresolved, rather than blocking further. Gate the tool with `check_available()` on `GITHUB_TOKEN`
presence, matching `gitnexus.py`/`rag.py`.

### Required skills
- backend-engineer
- python-best-practices

### Subtasks
- [ ] Add shared GitHub PR client functions (new module or extension of `document_repo.py`,
      implementer's choice per `technical-design.md` §4) for: get PR metadata, get PR diff, list
      PR files, list PR commits, list PR comments (issue + review comments), list PR reviews, get
      check-runs for a SHA (bounded poll), compare two refs, get file content at a ref, list open
      PRs for a repo.
- [ ] Add `plugins/tools/github_pr_context.py`: `SCHEMA` with the `action` enum + per-action
      required fields (`pr_url` for PR-scoped actions; `repo`/`ref`(s) for `list_prs`, `compare`,
      `file_at_ref`), `handle()` dispatching to the client functions, `check_available()` gated on
      `GITHUB_TOKEN`.
- [ ] Register the tool in `plugins/__init__.py`'s `_TOOLS` tuple.
- [ ] Add `CHAT_REVIEW_CI_POLL_TIMEOUT_SECONDS` env var (default `60`), documented in
      `.env.example`.
- [ ] Unit tests: one per `action`, mocking GitHub API responses; a test for the bounded poll
      timeout path (returns `pending` rather than blocking past the window); a test confirming
      `check_available()` gates the tool off when `GITHUB_TOKEN` is unset.

---

## T2 — PR review posting tool (two-call pattern + self-review handling)

### Description
Implements product-spec G3 per `technical-design.md` §4. Add `plugins/tools/github_pr_review.py`
implementing the orchestrator skill's Step 6 two-call posting pattern (verbatim copy in
`product-spec.md`'s Appendix): POST the full review narrative to `/issues/{n}/comments` (always
attempted; fatal on non-422 failure), then POST `/pulls/{n}/reviews` (skip gracefully on HTTP 422
self-review restriction — set `self_review_skipped: true`, do not fail the tool call). Reuses T1's
shared GitHub client for auth/headers. Per NG5, this tool never merges — it stops after posting.

### Required skills
- backend-engineer
- python-best-practices

### Subtasks
- [ ] Add `plugins/tools/github_pr_review.py`: `SCHEMA` (`pr_url`, `event`: `APPROVE` |
      `REQUEST_CHANGES`, `body`, `comments[]` with `path`/`line`/`body`), `check_available()`
      gated on `GITHUB_TOKEN`.
- [ ] Implement the two-call pattern: issue-comment POST (always attempted, fatal on non-422
      failure) then reviews POST (HTTP 201 → capture `review_url`; HTTP 422 → set
      `self_review_skipped: true`, keep the comment URL as `review_url`; any other error → fatal).
- [ ] Register the tool in `plugins/__init__.py`'s `_TOOLS` tuple.
- [ ] Unit tests: `APPROVE` happy path, `REQUEST_CHANGES` happy path, HTTP 422 self-review path
      (tool call must not fail), non-422 failure path (fatal), inline-comment formatting for
      `comments[]`.

---

## T3 — Rewrite bundled `review-pr` skill doc to the new tool-call sequence

### Description
Reactivates the already-bundled-but-inert `plugins/skills/technical_skills/review-pr/SKILL.md`
(per `technical-design.md` §1, §4) by rewriting its bash/`curl`-based execution steps into a
tool-call sequence: `load_skill("review-pr")` → one or more `github_pr_context` calls (diff,
metadata, checks) → apply `review_criteria.md` as an ordinary LLM reasoning turn → `github_pr_review`
to post. Drop the sections that don't apply to chat (`result.json` schema, cycle-limit gating,
task-YAML reads, Step 7 merge) and replace with a one-line note that chat-invoked reviews stop
after posting (NG5). Add a "last synced from `<commit-sha>`" marker to
`references/review_criteria.md` recording the `project-workspace` commit this mirror was copied
from (§3c / OQ4 — manual re-copy discipline, no new sync infra). Per NG1, the orchestrator's own
`.claude/skills/review-pr/` in `project-workspace` is not touched by this task.

### Required skills

### Subtasks
- [ ] Rewrite `plugins/skills/technical_skills/review-pr/SKILL.md`'s execution steps to reference
      `load_skill`, `github_pr_context`, and `github_pr_review` by their final tool names/schemas
      from T1/T2 — not bash/`curl`.
- [ ] Remove `result.json` schema, cycle-limit-check, and task-YAML-read sections; remove Step 7
      (merge); add a one-line note that chat-invoked reviews stop after posting the review.
- [ ] Add a "last synced from `<commit-sha>`" HTML comment marker at the top of
      `references/review_criteria.md`, recording the `project-workspace` commit SHA of
      `.claude/skills/review-pr/references/review_criteria.md` as of this sync.
- [ ] Confirm `project-workspace/.claude/skills/review-pr/` is unmodified by this task (NG1).

---

## T4 — `ReviewCard` chat rendering (optional fast-follow)

### Description
Optional UI enhancement per `technical-design.md` §4, §6 — **not required** for the G1–G7
acceptance criteria, since the model's own final-turn chat reply already satisfies G4 (a
severity-tagged summary + review link) without any frontend change. Adds a `ReviewCard` component
mirroring `tool-cards/document-edit-card.tsx`'s shape (icon, verdict badge, finding-count summary,
review URL link) and wires a `name === "github_pr_review"` branch in `message-thread.tsx`, replacing
the generic collapsible JSON dump for this tool's output. No change is needed to
`slash-command-picker.tsx` or `services/hermes-agent/tools.ts` — the picker auto-derives from
`plugins._TOOLS` registration (T1/T2), so both new tools already appear as slash commands once
registered.

### Required skills
- frontend-engineer
- nextjs-best-practices
- typescript-best-practices
- heroui-react

### Subtasks
- [ ] Add `ReviewCard` component under `src/components/agent-chat/tool-cards/`, mirroring
      `document-edit-card.tsx`'s structure, rendering: verdict badge (`APPROVE` /
      `REQUEST_CHANGES`), finding-severity counts, and a link to `review_url`
      (or a note when `self_review_skipped` is `true`).
- [ ] Add a `name === "github_pr_review"` branch in `message-thread.tsx`'s `ToolCallRow` to render
      `ReviewCard` instead of the default collapsible JSON block.
- [ ] Confirm (no code change expected) that `github_pr_context`/`github_pr_review` already appear
      in the slash-command picker once T1/T2 are merged, since the picker auto-derives from the
      `/tools` endpoint.
