# Technical Design: Agent Chat PR Review

## Feature
- Feature ID: `m3-agent-review-pr-skill`
- Status: **draft** — awaiting human approval

---

## 1. Current State

**Orchestrator's `/review-pr` skill** (`.claude/skills/review-pr/SKILL.md`, embedded verbatim in
`product-spec.md`'s Appendix) runs as a bash/git execution skill inside the orchestrator's
autonomous executor. It parses a PR URL, fetches the diff and CI check-runs via `curl` +
`$GITHUB_TOKEN`, applies `references/review_criteria.md` (an LLM reasoning step over the diff),
posts a two-call GitHub review (issue comment + review event, with 422 self-review handling),
optionally squash-merges, and writes `result.json` for the orchestrator's task-state routing.

**M3 Agent Chat / hermes-agent tool architecture** (verified against the hermes-agent repo):
- Tools are one Python module per tool under `plugins/tools/*.py`. Each exports a `SCHEMA`
  (JSON-Schema passed to the LLM), a `handle(...)` function, and optionally a `check_available()`
  gate. All tools are registered in a single tuple in `plugins/__init__.py:74-158`; `register(ctx)`
  (lines 161-175) wires each into `ctx.register_tool(...)`. `_json_result_handler`
  (`plugins/__init__.py:47-70`) JSON-stringifies the handler's return value into a `tool` message
  in the chat stream.
- Two existing tools already follow the "one tool, `tool=`/`action=` enum selector" pattern for a
  family of related read operations against an external service: `plugins/tools/gitnexus.py:42-96`
  and `plugins/tools/rag.py:14-97`, both gated by a `check_available()` that checks for a URL env
  var (`GITNEXUS_MCP_URL`, `RAG_MCP_URL`).
- **GitHub is already integrated, but narrowly.** `plugins/document_repo.py` is a plain-`requests`
  client (`_GITHUB_API_URL`, `_headers(token)` at lines 47-52) used by
  `plugins/tools/{approve,edit,artifacts,read,tasks_write,approval}.py` and the
  `documents.py`/`stages.py` routers. Every caller reads `GITHUB_TOKEN` from the environment ad hoc
  (`os.environ.get("GITHUB_TOKEN", "").strip()`, e.g. `read.py:93-95`) — there is no config/settings
  class. It is a **single shared bot PAT**, not per-user, and today's usage is scoped to the
  **management repo only** (spec/task doc reads/writes, PR creation for docs). Nothing today reads
  a PR's diff, files, comments, or reviews on an **implementation** repo, or posts a review.
- **The `review-pr` skill is already bundled in hermes-agent, but inert.** Contrary to this
  feature's original problem framing (which assumed it was absent), `review-pr` and
  `respond-to-review` already exist as knowledge-only *technical_skills* at
  `plugins/skills/technical_skills/review-pr/{SKILL.md,references/review_criteria.md}`. They were
  dropped in wholesale by commit `5d030f081` (v3 chat feature) and touched exactly once since, in
  `04a1279fa`, to reword GitNexus tool references (`mcp__gitnexus__*` → `query_gitnexus`) — not to
  keep pace with the orchestrator's rubric. `plugins/skills/index.py` only indexes this bundled
  directory for the `load_skill` tool (`plugins/tools/skills.py`); it has no connection to any
  executable review action, and no sync script exists anywhere (`Makefile`, CI workflows,
  `pyproject.toml` all checked) to keep it current with `project-workspace/.claude/skills/`.
- **Slash-command picker is fully auto-derived.** `digital-factory-ui/src/services/hermes-agent/tools.ts:27-32`
  calls `GET /tools`, proxied to `src/api/routers/tools.py:18-62`, which iterates the live
  `plugins._TOOLS` registry (dropping any tool whose `check_fn` gates it off) and returns tool
  names/descriptions. `slash-command-picker.tsx:33-40` maps every entry to a `/`-prefixed command
  — there is **no separate UI-side allowlist**. Registering a new hermes-agent tool makes it appear
  in the picker for free; `skills` (the `load_skill`-reachable set) are not surfaced this way.
- **Tool-result rendering** (`message-thread.tsx:187-230`) defaults to a collapsible row that
  expands into a raw `JSON.stringify` block. A small number of tools get a bespoke card via
  explicit `name === "..."` branches (`ApprovalCard`, `DocumentEditCard` at
  `tool-cards/document-edit-card.tsx`) — an established, low-cost pattern for richer rendering
  when warranted.
- `user-service` has no GitHub-specific identity fields anywhere (`internal/oauth/provider.go`'s
  `UserInfo` is provider-agnostic; no GitHub PAT/OAuth storage, no workspace-member→GitHub-account
  mapping). There is no per-user credential or identity to draw on for this feature.

---

## 2. Problem Framing

**Must change:**
- The chat agent needs real, executable GitHub read access (PR diff/files/metadata/comments/
  review-history/CI-status/commits/compare/file-at-ref/open-PR-listing — product-spec G7) and a
  real review-posting capability (G1–G4), where today it has neither.
- The already-bundled `review-pr` technical skill needs to become *reachable* — paired with tools
  that can actually execute what it describes — rather than remaining inert prose.

**Must remain stable:**
- The orchestrator's own `.claude/skills/review-pr/` and its `result.json`/task-YAML contract
  (product-spec NG1, NG2, NG4) — this feature does not touch orchestrator internals.
- Chat's triggered-only dispatch model (NG3) — no new autonomous behavior.
- `document_repo.py`'s existing management-repo-scoped functions and callers — unchanged.
- No PR merging from chat (NG5).

**Fixed assumptions (confirmed during this design, updates the product spec's working
assumptions):**
- There is no per-user GitHub identity anywhere in this stack. All GitHub writes from hermes-agent
  — including anything this feature adds — happen under the **existing shared bot `GITHUB_TOKEN`**.
  This resolves OQ2 (posting identity) definitively: reviews post as the bot, same as every other
  GitHub write hermes-agent already performs.
- Tool registration is global, not container-scoped (no per-thread-type gating exists in
  `plugins/__init__.py` today). Restricting a tool to "feature threads only" would require new
  context-aware `check_fn` plumbing that doesn't exist yet.
- The rubric text (`review_criteria.md`) is **already sitting in the hermes-agent repo** — it does
  not need a new mirroring mechanism, only a decision about how it gets *used* (see §3) and kept in
  sync (OQ4).

---

## 3. Options Considered

### 3a. Shape of the read-only GitHub context tool (G7)

**Option A — One tool per read operation** (`get_pr_diff`, `get_pr_files`, `get_pr_comments`,
`get_pr_reviews`, `get_checks`, `list_commits`, `compare_refs`, `get_file_at_ref`, `list_open_prs`
— 9 separate tools)
- Pros: narrowest possible JSON schema per call; simplest individual handler.
- Cons: inconsistent with the codebase's existing convention (`gitnexus.py`, `rag.py`) of one tool
  with an `action=`/`tool=` enum for a family of related operations; clutters the auto-derived
  slash-command picker with 9 new entries for what is conceptually one capability area.
- Implementation impact: 9 `SCHEMA`/`handle()` pairs, 9 registry entries.

**Option B — One tool, `action=` enum selector (chosen)**
- A single `github_pr_context` tool with an `action` parameter (`diff | files | metadata |
  comments | reviews | checks | commits | compare | file_at_ref | list_prs`), matching the
  `gitnexus.py`/`rag.py` precedent exactly.
- Pros: one registry entry, one slash-command surface, consistent with existing conventions,
  easiest for a future engineer to find and extend.
- Cons: slightly larger single `SCHEMA` (conditional required fields per action) and a dispatch
  branch inside one `handle()`.
- Implementation impact: one new tool module + one new shared GitHub client module (extending the
  `_headers()`/`requests` pattern from `document_repo.py` to implementation-repo PR endpoints).

### 3b. How the review rubric gets applied (G1–G4)

**Option A — Monolithic Python handler that mirrors the orchestrator skill 1:1**
- A single tool function does everything the orchestrator skill's steps 1–9 do, including "apply
  `review_criteria.md` to the diff."
- Cons: rubric application is a **judgment step** — deciding whether a given line is a 🔴/🟡/🟢
  finding requires reasoning over code semantics, not a deterministic Python routine. A Python
  handler cannot perform this step itself without invoking a *second, nested* LLM call from inside
  a tool handler — an unusual, unsupported pattern in this architecture (tools are leaf calls in a
  single model-driven loop, not sub-agents). Rejected: architecturally awkward and untestable in
  the same way the rest of the codebase's tools are tested.

**Option B — Model-sequenced tool calls, guided by the (edited) bundled skill doc (chosen)**
- The already-bundled `plugins/skills/technical_skills/review-pr/SKILL.md` is edited to describe a
  chat-native procedure: call `load_skill("review-pr")` (already works today, unchanged) to load
  the rubric and procedure into context, call `github_pr_context` (§3a) for diff/metadata/CI
  status, **reason over the diff against the rubric as an ordinary LLM turn** — exactly the
  judgment step the orchestrator's own executor performs — then call a new `github_pr_review` tool
  with the resulting verdict/findings to post the GitHub review.
- Pros: the judgment step happens where the codebase already does judgment (LLM reasoning in the
  main loop), reuses `load_skill` instead of building a second, redundant delivery mechanism for
  the same text, and needs only two new tool modules. From the user's perspective this is still one
  capability — "ask `@agent` to review a PR" — the multi-step sequencing is invisible to them and
  driven by the model, not a manual multi-command UX.
- Cons: correctness depends on the model reliably following a multi-step skill doc rather than a
  single deterministic function; needs the skill doc rewritten from bash/curl instructions to
  tool-call instructions.
- Implementation impact: two new tool modules (`github_pr_context`, `github_pr_review`) + an edit
  to the bundled `SKILL.md` (not the orchestrator's copy — NG1 is unaffected).

### 3c. Rubric sync mechanism (OQ4)

**Option A — Automated cross-repo CI diff check**
- A hermes-agent CI job checks out `project-workspace` and fails the build if
  `plugins/skills/technical_skills/review-pr/references/review_criteria.md` has drifted from
  `.claude/skills/review-pr/references/review_criteria.md`.
- Pros: drift becomes impossible to miss.
- Cons: requires hermes-agent CI to have read access to a second, private repo (new CI credential
  surface) for a file that changes rarely. Meaningfully more infrastructure than the problem
  currently warrants. Rejected for v1 — revisit if drift becomes a recurring real problem.

**Option B — Manual re-copy discipline + a "last synced" marker (chosen for v1)**
- Add an HTML comment at the top of the mirrored `review_criteria.md` recording the source commit
  SHA it was last synced from. Whoever edits the orchestrator's rubric going forward is
  responsible for re-copying it into hermes-agent and updating the marker (this is the same
  manual-copy convention that got the file there in the first place — formalized, not new).
- Pros: zero new infrastructure; matches how every other mirrored skill got into hermes-agent.
- Cons: relies on human/agent discipline; can still drift silently between conscious re-syncs.

### 3d. Chat container scope for v1 (OQ3)

**Option A — Feature-thread-only, gated by a new context-aware `check_fn`**
- Cons: no confirmed way today for a tool's `check_fn` to know which container type (feature
  thread vs. team thread vs. channel) it's being evaluated in — would need a small architecture
  spike before this feature could even start. Rejected for v1 given no functional risk from
  shipping broader (see Option B).

**Option B — Ship enabled in all containers (chosen)**
- Since the tool is strictly `@agent`-mention/slash-triggered (NG3 — no autonomous dispatch), there
  is no incremental risk to enabling it in team threads/channels alongside feature threads.
  Restricting scope would be a UX/product decision, not a safety one, and the product spec did not
  identify a reason to withhold it from any container.
- Cons: none identified beyond "more surface than strictly asked for" — acceptable given zero
  extra engineering cost.

### 3e. CI-poll timeout for a synchronous chat turn (OQ5)

**Option A — Mirror the orchestrator's 10-minute poll**
- Cons: blocks a live, latency-sensitive chat turn for up to 10 minutes. Rejected — chat users are
  actively waiting on a response; this would read as a hang.

**Option B — Short bounded poll, then "still pending" (chosen)**
- Poll CI check-runs for up to 60 seconds (4 polls, 15s apart), matching the product spec's "CI
  still resolving" user flow. If unresolved, `github_pr_context(action="checks")` returns a
  `pending` status and the model tells the user to retry once CI is green, rather than blocking
  further.
- Configurable via an env var (`CHAT_REVIEW_CI_POLL_TIMEOUT_SECONDS`, default `60`) for future
  tuning without a code change.

---

## 4. Chosen Design

Two new hermes-agent tool modules, plus a targeted edit to the already-bundled skill doc. No
required changes to digital-factory-ui (the slash-command picker auto-derives from tool
registration — this is a scope reduction versus the product spec's assumption that a UI change
might be needed).

**`plugins/tools/github_pr_context.py`** (read-only, satisfies G7 standalone and as the review
flow's fetch step):
- `SCHEMA`: `action` enum (`diff | files | metadata | comments | reviews | checks | commits |
  compare | file_at_ref | list_prs`) + `pr_url` (or `repo`/`ref` for `list_prs`, `compare`,
  `file_at_ref`).
- `check_available()`: gated on `GITHUB_TOKEN` presence, same convention as `gitnexus.py`/`rag.py`.
- `handle()`: dispatches to functions in a new shared client module (extending
  `document_repo.py`'s `_headers()`/`_GITHUB_API_URL` pattern, or a sibling module
  `plugins/github_pr_client.py` if keeping management-repo and implementation-repo concerns
  separate reads cleaner — left to implementation, not a design-relevant choice) that call the
  GitHub REST API: `GET /repos/{o}/{r}/pulls/{n}`, `.../files`, `.../commits`,
  `/issues/{n}/comments`, `/pulls/{n}/reviews`, `/commits/{sha}/check-runs`,
  `/compare/{base}...{head}`, `/repos/{o}/{r}/contents/{path}?ref={ref}`, `/repos/{o}/{r}/pulls`.
  `checks` implements the bounded poll from §3e.

**`plugins/tools/github_pr_review.py`** (write, satisfies G3):
- `SCHEMA`: `pr_url`, `event` (`APPROVE` | `REQUEST_CHANGES`), `body` (narrative), `comments[]`
  (inline findings: `path`, `line`, `body` with severity marker).
- `check_available()`: same `GITHUB_TOKEN` gate.
- `handle()`: implements the orchestrator skill's Step 6 two-call pattern verbatim — POST the full
  narrative to `/issues/{n}/comments` (always attempted, fatal on non-422 failure), then POST
  `/pulls/{n}/reviews` (skip gracefully on HTTP 422 self-review restriction, matching the
  orchestrator's `self_review_skipped` handling from the product-spec Appendix). Returns
  `{review_url, self_review_skipped}` so the model can report it in its chat summary (G4 is
  satisfied by the model's own final-turn prose, not by new tool-result rendering — no
  digital-factory-ui change is required for this).

**Skill doc edit** — `plugins/skills/technical_skills/review-pr/SKILL.md` (hermes-agent's bundled
copy; the orchestrator's `.claude/skills/review-pr/` in `project-workspace` is untouched, per
NG1): rewrite the bash/`curl` execution steps into a tool-call sequence — `load_skill("review-pr")`
→ `github_pr_context` calls for diff/metadata/checks → apply `review_criteria.md` as an ordinary
reasoning step → `github_pr_review` to post. Explicitly drop the sections that don't apply to chat:
`result.json` schema, cycle-limit gating, task-YAML reads, and Step 7 (merge) — replaced with a
one-line note that chat-invoked reviews stop after posting (NG5).

**Rubric**: no new mirroring work. `references/review_criteria.md` already exists in hermes-agent;
add the "last synced from `<commit-sha>`" marker (§3c) as part of the same edit.

**Credential**: reuse the existing shared `GITHUB_TOKEN` (§1, §2) against implementation-repo PR
endpoints, in addition to its current management-repo-only usage. Scope verified (§5, D1) —
the token has read/write access on implementation repos, not just the management repo.

**Container scope**: enabled everywhere (§3d) — no gating code.

**End-to-end flow**: a workspace member `@mention`s the agent with a PR URL and a review request →
the model calls `load_skill("review-pr")`, then `github_pr_context` one or more times, reasons
against the loaded rubric, then calls `github_pr_review` → the tool posts the review and returns
the URL/self-review flag → the model's own chat reply summarizes the verdict and findings with a
link, satisfying G4 without any new frontend work.

---

## 5. Dependency Analysis

**Internal:**
- `plugins/__init__.py` — register the two new tools in the `_TOOLS` tuple.
- `plugins/skills/technical_skills/review-pr/SKILL.md` — rewritten per §4 (hermes-agent's bundle
  only, not the orchestrator's skill — confirmed no NG1 conflict).
- New shared GitHub PR client code, extending `document_repo.py`'s auth/header pattern to
  implementation-repo PR endpoints.

**External:**
- GitHub REST API: `pulls`, `pulls/.../files`, `pulls/.../reviews`, `issues/.../comments`,
  `commits/.../check-runs`, `compare`, `contents`, plus repo-level `pulls` listing — all new
  surface for the existing shared token, previously only used against management-repo content
  endpoints.

**Resolved during design:**
- **`GITHUB_TOKEN` scope — verified.** The existing token has been confirmed to have read/write
  scope on the implementation repos this feature needs (`hermes-agent`, `digital-factory-ui`,
  `workflow-backend`, etc., as listed in `workspace.yaml`), not just the management repo. `D1` in
  §6 is cleared — `T2` (the posting tool) is no longer blocked on a credential-provisioning step.

**Remaining considerations:**
- **Self-review collision is not an edge case here.** Because every hermes-agent GitHub write uses
  one bot identity, any PR opened under that same identity (e.g. PRs the orchestrator itself opened
  using a related bot account, if they share an identity) will hit the HTTP 422 path on every chat
  review attempt, not occasionally. The 422-skip behavior (§4) must work correctly from the first
  release, not be treated as a rare branch.

**Vendor/tooling:** none new — reuses `requests`, already a hermes-agent dependency.

**Configuration:** one new optional env var, `CHAT_REVIEW_CI_POLL_TIMEOUT_SECONDS` (default `60`);
can be hardcoded initially and made configurable later without a design change.

**Release:** no schema/migration impact; pure application-code change following hermes-agent's
existing release process.

---

## 6. Parallelization / Blocking Analysis

```
D1: Verify GITHUB_TOKEN read/write scope on implementation repos (ops/human action) ── VERIFIED,
    scope confirmed — no longer a blocker

T1: Read-only GitHub PR context tool + shared client — hermes-agent
  └── Can begin now — no blockers
  │
  T2: PR review posting tool (two-call pattern + self-review handling) — hermes-agent
    └── BLOCKED on T1 (shares the GitHub client module T1 introduces)
    └── D1 cleared — credential scope no longer a blocker for this task
  │
  T3: Rewrite bundled review-pr skill doc to the new tool-call sequence — hermes-agent
    └── BLOCKED on T1 (read tool name/schema must be final to document)
    └── BLOCKED on T2 (posting tool name/schema must be final to document)
  │
  T4: ReviewCard chat rendering (optional, fast-follow) — digital-factory-ui
    └── BLOCKED on T2 (needs T2's final output shape to render)
    └── Not required for G1-G7 acceptance criteria — the model's own chat reply already
        satisfies G4; ship independently whenever picked up
```

---

## 7. Repository Impact

| Repo | Change |
|---|---|
| `hermes-agent` | New `plugins/tools/github_pr_context.py`, new `plugins/tools/github_pr_review.py`, new/extended shared GitHub PR client module, registration in `plugins/__init__.py`, rewrite of `plugins/skills/technical_skills/review-pr/SKILL.md`, "last synced" marker added to `references/review_criteria.md`. |
| `digital-factory-ui` | No required change — slash-command picker auto-derives from tool registration. Optional fast-follow: a `ReviewCard` component (mirroring `document-edit-card.tsx`) for richer tool-result rendering. |

No other repo in `workspace.yaml` is touched by this feature.

---

## 8. Validation and Release Impact

**Testing expectations:**
- Unit tests for the new GitHub PR client functions (mock GitHub API responses) covering each
  `github_pr_context` action, and `github_pr_review`'s two-call pattern including the HTTP 422
  self-review path (must not fail the tool call; must set `self_review_skipped: true`).
- A test for the bounded CI-poll timeout path (§3e) — confirms it returns `pending` rather than
  blocking past the configured window.
- Confirm `check_available()` correctly gates both new tools off when `GITHUB_TOKEN` is unset,
  matching the existing `gitnexus.py`/`rag.py` convention.

**Migration/config impact:** none — no DB schema change; `GITHUB_TOKEN` already exists in the
environment (scope verification is operational, per §5, not a migration).

**Rollout concerns:**
- This is a **permission expansion**: the existing bot token moves from management-repo-only usage
  to posting reviews on implementation repos. Scope has been verified (D1) as capable of this;
  the remaining consideration is that the shared bot identity's blast radius is now larger in
  practice, not just in theory — worth a quick security/ops sign-off before enabling in any
  environment where that matters, on the basis that it *will* happen, not that it merely *could*.
- No feature flag is strictly required (tools are additive), but an explicit rollout switch can be
  added cheaply if a staged rollout is preferred.

**Backward compatibility:** fully additive. No existing tool, skill, or `document_repo.py` caller
is modified. The orchestrator's own `/review-pr` skill and task-state machine are untouched (NG1).

**Deployment/handoff implications:** update hermes-agent's operator-facing docs to note the new
GitHub write capability and its shared-identity implications; no orchestrator or workflow-backend
deployment changes required.
