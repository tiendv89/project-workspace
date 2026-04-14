# Technical Design

## Feature
- Feature ID: `distributed-agent-team`
- Title: Distributed agent team (self-activating agents pulling work from workspace)

## Current State

### What exists in the workflow today
- Tasks are YAML files with `execution.actor_type: human | agent | either` — the `agent` designation is currently *documentation only*.
- `start-implementation` is the manual dispatch path: a human runs it, it validates readiness + dependencies, resolves env, checks out a branch, and logs a `started` action. It does not do the work — a human (or Claude Code session) does.
- `pr-create` and `pr-self-review` are existing skills usable for the handoff phase.
- `resolve-project-env` is the shared env-reading contract; already required by `start-implementation` and `pr-create`.
- The workflow repo is itself a git repo (`git@github.com:tiendv89/agent-workflow.git`) — same distribution path an agent image can consume.
- Base branches are per-repo via `workspace.yaml.repos[].base_branch` (no global default; decision already locked during product-spec stage).

### What does not exist
- No agent identity concept.
- No self-activation loop.
- No claim protocol.
- No token/iteration budget enforcement.
- No container runtime.
- No structured activity log for agents.

### Things we extend vs. build new
| Existing | New |
|---|---|
| `resolve-project-env` (no change) | `init-agent`, `agent-activate`, `agent-status` skills |
| `pr-create` (reused inside execution contract) | Agent Docker image + entry-point supervisor |
| `pr-self-review` (reused) | `agent.yaml` schema |
| Task YAML schema (one new log `action`) | `log.jsonl` local log schema |
| `start-implementation` (unchanged; agents do NOT invoke it) | Per-agent workspace folder convention |

## Constraints

Inherited from the product spec (non-negotiable):

1. **Idle polling must burn zero Anthropic tokens.** Eligibility matching, git ops, and claim attempts are pure code.
2. **One API key per agent.** No key sharing.
3. **Per-task token budget** with abort-and-block behavior; usage logged in the task `log`.
4. **Kill switch** — `agent.yaml.enabled = false` stops new claims on next cycle.
5. **Agents never mutate** review fields or mark tasks `done`.
6. **Per-agent folder ownership** — nothing shared between agents on one host.
7. **Git is the only coordination surface.** No agent-to-agent channel, no external locks.
8. **No pre-registration.** Agents have no central registry and no `agent_id`. Attribution in commits and log entries is `GIT_AUTHOR_EMAIL` from the host's `.env` — the identity already required for every git operation. Shared git identity across multiple agents is safe: different tasks never collide, and same-task claim races are resolved by commit SHA (not identity).
9. **Agents only use the shared workflow.** They consume existing skills (`pr-create`, `pr-self-review`); they do not define new workflow rules.
10. **Uniform fleet.** All agents in a deployment run deployment-identical containers — same image, same skill superset (whatever the pulled workflow repo contains), same budgets, same model tier configuration. There is no agent-side `role` or `skills[]` capability list. Any agent can take any task whose declared required skills resolve to directories under the pulled `workflow/technical_skills/`. Per-task capability is driven by the tech-lead's `### Required skills` declaration in `tasks.md`, not by agent configuration.
11. **No automatic retry on task failure.** When a task exits with any `blocked_reason` (budget exhausted, iteration cap, no progress, escalation requested, missing skill, runtime error, …), its status becomes `blocked`, not `ready`. No watchdog ever auto-promotes `in_progress` → `ready`. Because the fleet is uniform, a failure on one agent is a near-certain failure on any other; re-queueing would burn budget on guaranteed failure. Recovery is always a human action — either unblock with scope/refinement edits, or reset status to `ready`.

## Options Considered

Each section addresses one of the 7 open questions carried over from the product spec.

### Q1 — LLM model selection

**Where the LLM is actually invoked** (from the execution contract):
- Step 3: Implementation (heavy — code writing, test iteration)
- Step 4: Self-review (moderate — reviewing own diff)
- Step 5: PR description (light — summarization)
- Step 7b: `suggested_next_step` when blocked (light — one-shot explanation)

**Options:**
- **A. Single model** — Sonnet for everything. Simple, most expensive.
- **B. Two-tier** — Sonnet for implementation + self-review; Haiku for PR description + blocked suggestions. Pragmatic cost/quality split.
- **C. Three-tier** — Opus for "complex" tasks (when?), Sonnet default, Haiku for light. Requires task-complexity signal we don't have.
- **D. Per-task override** — task YAML declares `model:`. Maximum flexibility, but puts routing burden on the task author.
- **E. Per-phase allowlist with workspace defaults + task-level overrides** — `workspace.yaml` defines allowed models and a default per phase. Individual tasks override in `tasks.md`'s `### Model overrides` subsection. Agent uses the default from the merged allowlist; if unavailable, falls back to the cheapest allowed. Centralized cost control + per-task flexibility, no per-agent model config.

Trade-offs: (A) predictable but costly; (B) ~30-40% cheaper on light steps for negligible quality loss; (C) deferred until we see real workloads; (D) nice-to-have, not required v1; (E) best of (B) cost control + (D) flexibility — human controls the ceiling centrally while customizing per task during review.

### Q2 — Tool-use architecture

How does the agent actually *run code, edit files, run tests*?

**Options:**
- **A. Spawn Claude Code CLI as subprocess** — the agent's entry-point runs `claude -p "<task prompt>"` in the target repo's worktree. Claude Code handles its own tool-use loop (file edits, bash, etc.). Agent observes token usage from its output.
- **B. Anthropic Agent SDK** — build the tool-use loop ourselves using the Agent SDK (Python or TS). Direct control over budget, iteration counts, tool allow-lists.
- **C. Custom loop on raw Anthropic API** — maximum control, maximum effort. Basically reinvent Claude Code.

Trade-offs:
- (A) Re-uses an entire agent runtime already designed for this exact problem. Thinnest wrapper. Budget enforcement is **mid**: Claude Code exposes `--max-turns` but not a hard token cap; we approximate via max-turns + observed token count.
- (B) Firm budget enforcement (we stop the loop whenever tokens cross the threshold). More code we own.
- (C) Overkill for v1.

### Q3 — Implementation iteration strategy

How does the agent know when to stop iterating in step 3?

**Options:**
- **A. Hard iteration cap only** — run exactly N iterations, take the last result.
- **B. Success-signal driven** — stop on "tests + lint + typecheck all pass AND agent reports done."
- **C. Combined (cap + success-signal + no-progress detection)** — succeed on signal, fail on cap, also fail if two consecutive iterations hit the *same* error (infinite-loop guard).

Trade-offs: (A) risks wasting tokens when done early; (B) risks infinite loops when the agent can't make progress; (C) covers both.

### Q4 — Claim race hardening

Is git push-rejection enough, or do we need a short lease file before the claim?

**The claim sequence:**
1. Agent pulls workspace.
2. Agent identifies eligible task T.
3. Agent commits task update (status → in_progress, `execution.last_updated_by` set to `GIT_AUTHOR_EMAIL`, log entry appended).
4. Agent pushes. The claim library remembers the SHA of its just-pushed commit.
5. Either push succeeds (claim wins) or push is rejected. On rejection, agent fetches and compares HEAD to its remembered SHA: if they match the agent actually won (benign rebase); if they don't, someone else claimed the same task — agent abandons and moves on.
6. **No LLM call happens before step 5.** Token cost of a lost race is zero.

The commit-SHA check in step 5 is what keeps the claim protocol safe when multiple agents share a git identity — identity alone can't distinguish self from other, but the pushed SHA can.

**Options:**
- **A. Push-rejection is the only check** — on reject, agent inspects HEAD vs its remembered push SHA and drops or retries accordingly. No extra files.
- **B. Lease file before commit** — agent writes a lease file with task id + expiry, commits + pushes the lease first. Peers see the lease and skip. Adds latency and a second push.

Trade-offs: (A) is simple and correct for our case because git is fast-forward-only per branch, so exactly one claim wins. (B) only helps if we had a non-git coordination surface (we don't). (B) doubles the push count per cycle and adds lease cleanup work.

### Q5 — Activation trigger mechanism

How does the agent actually run on a schedule inside the container?

**Options:**
- **A. In-container supervisor loop** — entry-point is a shell loop: `while true; do check_enabled; run_activation; sleep $INTERVAL; done`. Docker `restart: unless-stopped` handles crashes.
- **B. Cron inside the container** — adds cron daemon, more moving parts.
- **C. One-shot containers triggered externally** — a Kubernetes CronJob, systemd timer, or GitHub Actions schedule spawns a container per cycle. Container runs one activation and exits.

Trade-offs:
- (A) Single process, clear lifecycle, simple logs. Sleep means it's not instant — but we accept that (polling interval is operator's lever).
- (B) Cron inside containers is an anti-pattern in general; avoid.
- (C) Cleanest in mature infra, more setup friction for operators who just want `docker compose up`.

### Q6 — Skill capability model

Skills live in the workflow repo (`workflow/technical_skills/`). The agent pulls the workflow repo at container start (T7). The question is: **who decides which skills a given task needs, and where is that declared?**

**Options:**
- **A. Declared on the agent (`agent.yaml.skills[]`).** Each agent announces a static skill set up-front. The eligibility matcher intersects `agent.skills ⊇ task.required_skills`. Agents can be heterogeneous — e.g. one image with backend skills, another with data-engineering skills. Requires operators to maintain per-agent configuration. Task authors must hope the agent pool collectively covers every skill they reference.
- **B. Declared on the task (`tasks.md.### Required skills`), agent is full-stack.** Every agent is deployed identically with access to the entire skill superset from the pulled workflow repo. The tech-lead annotates each task in `tasks.md` with the minimal skill set that task needs. The agent reads the annotation at claim time, loads those specific `SKILL.md` files into its system prompt, and runs. Eligibility filter drops any task whose declared skill is missing from the pulled workflow repo.
- **C. Hybrid.** Agent declares a *capability ceiling* in `agent.yaml.skills[]`, tech-lead declares a required set per task, matcher intersects and requires `task.required_skills ⊆ agent.skills`. Gives both sides a voice but doubles the surface area of mistakes (skill-name typos on either side become "agent silently ineligible").

**Trade-offs:**
- (A) Operationally complex; a new skill requires updating every agent's config. Benefit is fleet heterogeneity — useful if specialized agents (e.g. GPU-only builds) must be kept separate. We don't have that need in v1.
- (B) Zero per-agent configuration. Fleet is uniform and identical. Any agent can take any task whose skills are present in the pulled workflow repo. Failure mode is narrow: a tasks.md that references a non-existent skill is a tasks-stage authoring error, caught at eligibility scan time.
- (C) Over-engineered for v1. No compelling use case where both sides need a say.

Rationale for preferring (B): simpler operational model, agents are cattle not pets, skill management centralizes in the workflow repo (source of truth) rather than scattered across agent configs. It also aligns with Constraint #10 (uniform fleet).

### Q7 — Structured log format

Append-only event log for operators. Each line is one JSON event. The schema has to balance: enough to debug an incident, small enough to parse with `jq`.

Proposed schema (v1):

```json
{
  "at": "2026-04-13T12:34:56.789Z",
  "by": "backend-bot-01@team.com",
  "type": "task_claimed",
  "iteration": 1,
  "tokens": { "in": 0, "out": 0, "total": 0 },
  "duration_ms": 1234,
  "details": {}
}
```

The event line carries `by` = `GIT_AUTHOR_EMAIL` for attribution. Task identification comes from the filename (logs are task-scoped — see Q7 detail below), so `task_ref` is not repeated on every line.

**Event types:**
- `activation_start`, `activation_end` — cycle bounds
- `workspace_pull_ok`, `workspace_pull_failed`
- `task_eligible`, `task_claim_attempt`, `task_claimed`, `task_claim_rejected`
- `task_work_start`, `task_work_iteration`, `task_work_complete`, `task_blocked`
- `pr_created`, `pr_failed`
- `budget_exceeded`, `iteration_cap_hit`
- `error` (uncategorized)

## Chosen Design

| # | Question | Chosen | Rationale |
|---|---|---|---|
| Q1 | LLM model | **E — Per-phase allowlist (workspace defaults + task overrides)** | `workspace.yaml` `model_policy` defines allowed models and default per phase. Tasks override via `### Model overrides` in `tasks.md`. Agent uses merged default; falls back to cheapest allowed. Opus access = adding it to the task's allowlist during review. No per-agent model config. |
| Q2 | Tool-use architecture | **B — Anthropic Agent SDK** | Firm, code-level budget and iteration enforcement. Worth the extra implementation effort over Claude Code CLI for v1 — budget is a hard rule and must not rely on approximation. |
| Q3 | Iteration strategy | **C — Combined cap + success-signal + no-progress detection** | Default `max_iterations: 3`. Success = tests/lint/typecheck pass AND agent reports done. Fail on cap OR two consecutive identical failure signatures. |
| Q4 | Claim race | **A — Push-rejection only, no lease** | Git is fast-forward-strict on a branch; exactly one claim wins. No LLM tokens burned before the winning push. Lease files add cost without new safety. |
| Q5 | Activation trigger | **C — One-shot container triggered externally** | Container runs one activation and exits. Orchestration is pluggable: k8s CronJob (primary target), docker-compose with a supervisor sidecar, cron, or systemd timer. Fits ephemeral runtimes cleanly. |
| Q6 | Skill capability model | **B — Full-stack agents; tech-lead declares `### Required skills` per task in `tasks.md`** | Agents are uniform and identical across the fleet. No per-agent skill list. Tech-lead picks the minimal skill set each task needs; agent loads them dynamically from the pulled workflow repo at run-task time. Eligibility filter drops tasks whose declared skills don't exist in the repo. |
| Q7 | Log storage | **Per-run JSONL file under `docs/features/<feature_id>/logs/T<n>_<ISO-start>.jsonl` on the task's feature branch** | Task-scoped (one file per run), merges to base with the task's PR. No orphan branch, no agent slug, no rotation. Pure append — no RMW on flush. Different tasks = different files = zero contention. Non-task events (bootstrap, idle polls) are stdout only for v1. |

### Q1 detail — Per-phase model policy and escalation

**Workspace-level defaults.** `workspace.yaml` carries a `model_policy` section defining, for each phase, the set of allowed models and the default:

```yaml
model_policy:
  implementation:
    allowed: [claude-sonnet-4-6]
    default: claude-sonnet-4-6
  self_review:
    allowed: [claude-sonnet-4-6]
    default: claude-sonnet-4-6
  pr_description:
    allowed: [claude-haiku-4-5-20251001]
    default: claude-haiku-4-5-20251001
  suggested_next_step:
    allowed: [claude-haiku-4-5-20251001]
    default: claude-haiku-4-5-20251001
```

The human workspace owner sets this once. All agents read the same policy. To enable Opus workspace-wide, add it to the relevant phase's `allowed` list and optionally change `default`.

**Task-level overrides.** In `tasks.md`, each `## T<n>` section may include an optional `### Model overrides` subsection:

```markdown
### Model overrides
implementation:
  allowed: [claude-sonnet-4-6, claude-opus-4-6]
  default: claude-opus-4-6
```

Only phases that differ from workspace defaults need to be listed. Merge rule: task-level replaces workspace-level for each declared phase; undeclared phases inherit workspace defaults.

**Runtime model selection.** At run-task time, the agent:
1. Reads `model_policy` from `workspace.yaml`.
2. Reads `### Model overrides` from the task's section in `tasks.md` (if present).
3. Merges: task overrides replace workspace defaults per phase.
4. For the current phase, uses `default`. If `default` is unavailable (API error, model deprecated), falls back to the cheapest model in `allowed`.
5. If the selected model is not in the phase's `allowed` list (configuration error), falls back to the cheapest model in `allowed` and emits a `model_fallback` log event.

**Escalation flow.** Agent starts with whatever `default` is set for `implementation` (typically Sonnet). If the agent self-detects insufficient capability (hits iteration cap, repeated failures, self-review flags complexity), it exits with:
```yaml
status: blocked
blocked_reason: model_escalation_requested
blocked_details:
  current_model: claude-sonnet-4-6
  reason: "Iteration 3 unable to resolve <X>; suggests architectural complexity"
```

A human reviews, then either:
- Adds Opus to the task's `### Model overrides` in `tasks.md` and resets `status: ready` — agent re-claims with Opus next cycle.
- Refines scope and re-readies without model change.

**Model selection rules per phase (after merge):**
- Implementation → merged `default` for `implementation` phase
- Self-review → same model as implementation (parity helps catch its own blind spots)
- PR description → merged `default` for `pr_description` phase
- `suggested_next_step` → merged `default` for `suggested_next_step` phase

**Human approval is implicit.** The human approves model usage by reviewing `### Model overrides` during task review (for pre-planned Opus) or by editing `tasks.md` after escalation. No separate approval fields on the task YAML. No `model_override_approved_by` ceremony.

### Q2 detail — Agent SDK implementation

Using the Anthropic Agent SDK (Python or TypeScript — decide during task breakdown):

- Agent code owns the tool-use loop. It exposes tools to the LLM for: bash, file read/write, git operations.
- Between iterations, the code checks `tokens_used_so_far > budget.max_tokens_per_task` → abort to 7a.
- After each iteration, the code checks `iteration_count >= budget.max_iterations` → abort to 7b.
- Consecutive identical failure signatures (hash of test output or error string) → abort to 7b with `no_progress` reason.
- Tokens per model are tracked separately (input vs. output, per model) and aggregated into the task log entry.

This path is more code than Claude Code CLI subprocess but gives us the budget guarantee the product spec requires.

### Q5 detail — One-shot activation + runtime orchestration

Container entry point is a single `agent-activate` invocation. It:
1. Reads agent.yaml from its config mount.
2. If `enabled: false`, exits immediately with code 0.
3. Runs one activation cycle.
4. Exits with code 0 (success) or non-zero (error, for the scheduler to surface).

**Orchestration patterns documented for operators:**

| Runtime | Trigger |
|---|---|
| Kubernetes | `CronJob` with `schedule: "*/5 * * * *"` and `concurrencyPolicy: Forbid` |
| docker-compose (dev) | Optional supervisor sidecar: small busybox container running `while true; do docker run <agent-image>; sleep 300; done` |
| Bare metal | `systemd` timer or `cron` calling `docker run <agent-image>` |
| GitHub Actions | Scheduled workflow calling the agent image on a runner |

**Kill switch semantics with one-shot:**
- `enabled: false` is checked at the top of each activation.
- If the scheduler keeps triggering, the agent starts up and exits within ~1 second each cycle. Cheap.
- For a hard stop, the operator also disables the scheduler (`kubectl patch cronjob ... --type merge -p '{"spec":{"suspend":true}}'`).

### Q6 detail — Per-task skill declarations and dynamic loading

**Where skills are declared.** In `tasks.md`, inside each `## T<n> — <title>` section, a new `### Required skills` subsection lists the skills the task needs. One skill per bullet. Skill names must match directory names under `workflow/technical_skills/`.

Example:
```markdown
## T5 — Integrate Anthropic Agent SDK tool-use loop with budget enforcement

### Description
…

### Required skills
- typescript-best-practices
- nestjs-best-practices

### Subtasks
- [ ] …
```

**Why `tasks.md` (not `tasks/T<n>.yaml`).** Per the workflow's narrative-vs-state split rule: the YAML carries only machine-mutable runtime state (status, deps, branch, log); logical intent lives in the human-authored markdown. `required_skills` is logical intent (tech-lead's decision about what the task needs), not runtime state — so it belongs in `tasks.md`.

**Parsing contract for the eligibility matcher.** The matcher is pure code — zero-token. It parses `tasks.md` as follows:
1. Scan for `## T<id> — …` headings.
2. Within each task section (bounded by the next `## ` or EOF), locate `### Required skills`.
3. Collect consecutive `- <slug>` lines until the next `###`, `## `, or EOF. `<slug>` must match `^[a-z0-9][a-z0-9-]*$`.
4. A task with no `### Required skills` subsection is treated as requiring **no skills** (a rare case, e.g. pure text tasks).
5. A malformed subsection (non-slug content, missing closing boundary) causes the matcher to log a `tasksmd_parse_warning` event to stdout and skip the task. The authoring error surfaces through operator logs, not through a silent match.

**Dynamic loading at run-task time.** After claim, before invoking the SDK loop, the agent:
1. Re-reads the claimed task's `### Required skills` from `tasks.md`.
2. For each slug, reads `workflow/technical_skills/<slug>/SKILL.md`.
3. Concatenates the SKILL bodies (in listed order) into a dedicated block of the system prompt alongside the task description and workspace context.

**Missing-skill handling (fail-fast at eligibility, not at claim).** Per Constraint #11, agents do not claim tasks they can't complete. The eligibility matcher — before any claim attempt — verifies that every `<slug>` in a task's `### Required skills` exists as a directory under the pulled `workflow/technical_skills/`. If any is missing, the task is ineligible for this activation cycle. The agent emits a `task_skipped_missing_skill` event to stdout naming the task and the missing skill(s). The task stays `ready` (not `blocked`) — a missing skill is a workflow-repo authoring issue, not a task-scope issue, and resolves by fixing the workflow repo, not by mutating the task.

**Bootstrap-time audit (informational, non-fatal).** At container start (after the workflow-repo pull), the bootstrap phase enumerates all `### Required skills` slugs across all `tasks.md` files in watched workspaces, and emits a `skill_reference_audit` event summarizing any slug that isn't backed by a directory. This gives operators a single up-front signal about stale or typo'd skill references without blocking activation.

**What tech-lead must do.** This is the rule the tech-lead skill grows (applied only after this design is re-approved): every generated `## T<n>` section in `tasks.md` must include a `### Required skills` subsection. Tech-lead picks the minimal set from the skills currently under `workflow/technical_skills/`. If an emerging task needs a skill that doesn't exist yet, the tech-lead flags it explicitly rather than inventing a name — new skills land through the workflow repo's normal authoring process before the referring task is approved.

**Retirement of `workspace.yaml.role_skill_overrides`.** Under the old model, `role_skill_overrides` mapped project-agent roles to enabled skill sets. With agents being full-stack and skills per-task, the mapping becomes redundant. `role_skill_overrides` is removed from the workspace schema. (See the workflow ripple list at the bottom of this design.)

### Q7 detail — Log durability + format

**Scope: task-scoped, per-run.** Each agent run of a given task writes its own JSONL file. No monthly rotation (tasks are bounded). No orphan branch. No agent slug in the path.

**Storage layout (inside each workspace):**
```
docs/features/<feature_id>/
  tasks.md
  tasks/
    T1.yaml
    T2.yaml
    …
  logs/
    T1_2026-04-13T14-30-00Z.jsonl   # first run of T1, may have ended blocked
    T1_2026-04-13T15-45-22Z.jsonl   # retry of T1
    T2_2026-04-13T14-32-15Z.jsonl
```

Filename shape: `T<n>_<ISO-start>.jsonl`, with `ISO-start` being the run-start UTC timestamp with colons replaced by dashes (filesystem-safe).

**Non-task events** (bootstrap, idle polls, eligibility scans, failed claim attempts with no winner to attribute to) go to **stdout only** for v1. They're visible via the orchestrator's native log channel (`kubectl logs`, `docker logs`, `journalctl`, GHA run log) while the container is alive. Durable fleet-level observability is deferred to a later feature.

**Write protocol (per run):**
1. On run start, the sink creates `docs/features/<feature_id>/logs/T<n>_<ISO-start>.jsonl` on the task's feature branch. First line is a `run_started` event carrying the run-level metadata (`task_id`, `by`, `run_started_at`, `trigger`).
2. Events buffer in memory during iteration; flushed at every iteration boundary and on graceful shutdown.
3. Each flush is a pure append to the file, then `git add` + commit + push on the task's feature branch.
4. On graceful shutdown, a final `run_ended` line carries outcome + `total_tokens` summary. Absence of this line marks the file as incomplete (pod killed mid-run).
5. Push rejection retry: fetch + rebase + re-push once. Single writer per feature branch so rebase is typically trivial. If retry fails, events are lost — logs are observability, not correctness.

**Log line format** (JSONL, one event per line):

```json
{
  "at": "2026-04-13T12:34:56.789Z",
  "by": "backend-bot-01@team.com",
  "type": "tool_called",
  "iteration": 1,
  "tokens": { "in": 1234, "out": 567 },
  "duration_ms": 120,
  "details": { "tool": "Edit" }
}
```

Task identification is the filename (`T1_<start>.jsonl`) — no need to repeat `task_id` on every line.

**Event types (v1):**
- `run_started`, `run_ended` — first and last lines of every complete run
- `workspace_pull_ok`, `workspace_pull_failed`
- `task_claimed`, `task_claim_rejected` (loser's perspective, rarely logged since loser has no task context; usually stdout only)
- `task_work_start`, `task_work_iteration`, `task_work_complete`, `task_blocked`
- `model_invoked`, `tool_called`
- `pr_created`, `pr_failed`
- `budget_exceeded`, `iteration_cap_hit`, `no_progress_detected`
- `model_escalation_requested`
- `error` (uncategorized)

**Branch merge behavior:** because logs live under `docs/features/<feature_id>/logs/` on the task's feature branch, they merge into the base branch alongside the task's PR. After the feature ships, each task's run history is preserved in the base branch under the feature's `logs/` folder — durable feature history, zero extra plumbing.

**Pluggable sinks (deferred to v2):** fleet-level or long-running observability (S3, CloudWatch, Grafana) can be added later via an optional sink adapter. The file-on-feature-branch sink remains the default.

### Integration points with existing workflow

- **`pr-create`** and **`pr-self-review`**: invoked in execution-contract steps 4 and 5. No changes to those skills' contract.
- **`resolve-project-env`**: invoked at container start to read the agent workspace `.env`. The agent workspace is itself treated as a project workspace from env-resolution's perspective. No changes.
- **Task YAML schema** (additive):
  - `blocked_reason: model_escalation_requested` — new valid value
  - `blocked_details: { ... }` — new optional object, used by escalation path
  - New `action` values in the task log: `submitted_for_review`, `model_escalation_requested`
- **`workspace.yaml`** (additive): new `model_policy` section with per-phase `allowed` + `default`. `base_branch` per repo already landed.
- **Workspace repo structure**: new `agents/` top-level folder (one sub-folder per agent, used for logs only in v1).

### Data & config schemas

**`agent.yaml`** (new — minimal shape, no capability declarations):
```yaml
# Attribution is GIT_AUTHOR_EMAIL from the host's .env — no agent_id field here.
# There is no agent-side role or skills list. Agents are uniform full-stack workers;
# per-task capability comes from tasks.md's ### Required skills subsection, loaded
# dynamically at run-task time from the pulled workflow/technical_skills/ directory.

watches:
  - git@github.com:tiendv89/workspace.git   # one or more workspace repos to scan
enabled: true                                # kill switch; false → exit 0 immediately
jitter_max_seconds: 15                       # pre-claim jitter to de-sync concurrent agents
budget:
  max_tokens_per_task: 200000
  max_iterations: 3
  suggested_next_step_max_tokens: 2000
log_sink:
  enabled: true                 # path is deterministic: docs/<feature>/logs/T<n>_<ISO-start>.jsonl
```

Notes:
- No `roles[]`, `skills[]`, `models`, `agent_id`, `display_name`, or `host` fields. The agent's identity is its git author email; its capability is whatever skills the pulled workflow repo contains. Model selection is driven by `workspace.yaml` `model_policy` + task-level `### Model overrides`, not by agent config.
- No `branch_pattern` or `file_pattern` under `log_sink` — path is fully derived from the task being worked on.
- `activation_interval_seconds` is NOT on the agent (see Q5 — orchestration is external). The scheduler (k8s CronJob, systemd timer, etc.) owns cadence.
- Fleet deployment is expected to use a single canonical `agent.yaml` replicated across hosts. Heterogeneous fleets are explicitly out of scope for v1 (Constraint #10).

**Task YAML (`tasks/T<n>.yaml`) — changes from prior shape:**
- **Removed: `role`.** Roles are dropped with the full-stack-agent model. If humans want to annotate who handles what, they do it in `tasks.md` prose — not in the machine-state YAML.
- All other fields unchanged: `id`, `title`, `repo`, `status`, `depends_on`, `blocked_reason`, `branch`, `execution.*`, `pr.*`, `log`.

**`tasks.md` — new required subsection per task:**

Every `## T<n> — <title>` section must include a `### Required skills` subsection. Grammar (the eligibility matcher depends on this being stable):

```
### Required skills
- <slug>
- <slug>
...
```

- `<slug>` matches `^[a-z0-9][a-z0-9-]*$` and must equal a directory name under `workflow/technical_skills/`.
- Empty required-skills list is valid (write the heading with no bullets, or omit the section entirely) — the task needs no skill context.
- Position: conventionally placed between `### Description` and `### Subtasks` for readability. The matcher does not depend on position, only on the subsection being present inside the task's `## T<n>` block.
- Authoring error (bad slug, malformed list) → task skipped by the matcher with a stdout warning; never silently matches.

**`### Model overrides` — optional per-task subsection in `tasks.md`:**

```
### Model overrides
<phase>:
  allowed: [<model_id>, ...]
  default: <model_id>
```

- `<phase>` must be one of: `implementation`, `self_review`, `pr_description`, `suggested_next_step`.
- Only phases that differ from `workspace.yaml` `model_policy` need to be listed.
- Merge rule: task-level replaces workspace-level for each declared phase; undeclared phases inherit workspace defaults.
- Position: conventionally placed after `### Required skills` and before `### Subtasks`. The parser scans within the task's `## T<n>` block (bounded by next `## ` or EOF).
- Absent `### Model overrides` subsection = task uses workspace defaults for all phases.
- Authoring error (unknown phase, missing `default`) → agent emits `model_override_parse_warning` to stdout and falls back to workspace defaults for that phase.

**Agent workspace layout:**
```
<agent_root>/
  agent.yaml                    # config (above)
  .env                          # ANTHROPIC_API_KEY, SSH_KEY_PATH, GH_TOKEN,
                                # GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL (attribution)
  docker-compose.yml            # generated by init-agent
  data/                         # mounted into container at /agent
    workspaces/
      <workspace_id>/           # one per watched workspace
        .git/
        docs/features/<feature_id>/logs/   # per-task, per-run logs live here,
                                           # committed to the task's feature branch
        ...
    workflow/                   # cloned shared workflow repo (for skills)
      .git/
      ...
    repos/                      # target repo clones
      <repo_id>/
        .git/
        ...
  (no persistent log.jsonl at this level — non-task events are stdout only)
```

**Docker image:**
- Base: `node:20-alpine` + `tini` (TypeScript runtime decided at task breakdown)
- Adds: `git`, `openssh-client`, the Agent SDK, the `agent-activate` code
- Entry point: single `agent-activate` invocation (one-shot); exits with status code
- Expects mounts: `/agent` (the `data/` above), `/agent-config` (the agent.yaml + .env)
- **Execution environment limitation (v1):** the image can only run tasks whose repos use Node.js/TypeScript toolchains natively. For repos in other languages (Python, Go, etc.), the agent would need the target language's runtime installed. This is intentionally deferred — see feature `agent-execution-environment` for the v2 solution (per-repo dev containers or equivalent).

### Repository layout

All new artifacts live inside the existing `workflow` repo (no new repository for v1). Extraction can be revisited later if the Docker image lifecycle diverges from the workflow.

```
workflow/
  workflow_skills/
    init-agent/          ← new
    agent-activate/      ← new (calls the Agent SDK runtime)
    agent-status/        ← new
    ... (existing, unchanged)
  agent-runtime/         ← new top-level directory
    Dockerfile
    src/                 ← Agent SDK-based activation code
    scripts/             ← entry point, helpers
    compose-templates/   ← docker-compose + k8s CronJob examples
    systemd-templates/   ← unit file + timer
  schemas/
    agent.yaml.example   ← new
    log.jsonl.schema.json ← new
  templates/
    agent-workspace/     ← new template (analogous to templates/workspace/)
```

## Dependency Analysis

Build order (arrows = "must be done before"):

```
[agent.yaml schema]    [log.jsonl schema]    [task YAML additions]
       |                      |                        |
       +----------+-----------+------------+-----------+
                  |                        |
                  v                        v
        [init-agent skill]        [agent-status skill]
                                           ^
                                           |
[Agent SDK runtime scaffold]               |
       |                                   |
       v                                   |
[claim protocol] + [budget/iteration enforcement] + [log sink (git commit)]
       |
       v
[execution contract code] (Opus approval, escalation path, pr-create/self-review integration)
       |
       v
[agent-activate skill + entry point]
       |
       v
[Docker image build + publish]
       |
       v
[Orchestration templates (k8s CronJob, docker-compose, systemd)]
       |
       v
[Operator docs + integration tests]
```

Blocking conditions:
- **All new skills** depend on the three schemas being frozen first (agent.yaml, log.jsonl, task YAML + workspace.yaml additions for model_policy + escalation).
- **Claim protocol**, **budget enforcement**, and **log sink** are siblings — can be built in parallel once schemas land.
- **Eligibility matcher** also depends on the `tasks.md` `### Required skills` grammar being frozen (part of the T1 schema work — the workflow-wide rule lands alongside `agent.yaml`).
- **Execution contract** (SDK loop) depends on all three siblings because it orchestrates them. It also reads `model_policy` from `workspace.yaml` + `### Model overrides` from `tasks.md`.
- **Docker image** depends on `agent-activate` being runnable outside the container first (don't debug two layers at once).
- **Orchestration templates** are additive; parallel with image build once image contract is known.
- **Documentation** lags implementation by one unit; starts once the image is runnable.

External dependencies (nothing blocks):
- Anthropic API access (already assumed).
- GHCR (image registry) — can be picked later per product spec note.

## Parallelization / Blocking Analysis

External dependencies: none blocking. Anthropic API access is already assumed; image registry choice (GHCR vs alternative) can be deferred per product spec.

```
T1: Update workflow rules for per-task skills + full-stack agents + model policy grammar (W1–W9, W12–W13)
  └── Can begin now — no blockers
  │
T2: Define agent.yaml schema and TypeScript validator
  └── Can begin now — no blockers
  │
T4: Implement git-commit log sink library (TypeScript)
  └── Can begin now — no blockers
  └── T1, T2, T4 run in parallel
  │
  T3: Extend task + workspace schemas (model_policy, escalation, drop role) (W6, W10)
      └── BLOCKED on T1 (W5 must have dropped role from schemas/task.yaml.example first; W2 must have codified the narrative/state split; model_policy grammar in tasks.md must be frozen)
      │
      T5: Implement zero-token eligibility matcher
          └── BLOCKED on T1 (### Required skills grammar must be frozen in CLAUDE.shared.md for the parser to follow a stable contract)
          └── BLOCKED on T2 (agent.yaml.watches shape must be settled so the matcher knows which repos to consider)
          └── BLOCKED on T3 (task YAML shape must be settled before the matcher consumes it)
          │
      T6: Integrate Anthropic Agent SDK tool-use loop with budget enforcement, dynamic skill loading, and model policy resolution
          └── BLOCKED on T2 (budget fields come from agent.yaml)
          └── BLOCKED on T3 (model_policy + escalation contract must be settled; workspace.yaml schema must be frozen)
          │
      T7: Implement git-based claim protocol with commit-SHA contention
          └── BLOCKED on T3 (claim mutates task YAML — needs final shape)
          │
      T8: Container-start workspace pull + fail-fast validation + skill_reference_audit event
          └── BLOCKED on T1 (### Required skills grammar frozen — audit reads it across all watched tasks.md)
          └── BLOCKED on T2 (bootstrap validates agent.yaml via T2's validator)
          │
          └── T5, T6, T7, T8 run in parallel once T1/T2/T3 land
          │
          T9: Build agent-runtime Docker image and contract
              └── BLOCKED on T4 (log sink library must be linkable into the image)
              └── BLOCKED on T5 (eligibility matcher runs on boot; must exist)
              └── BLOCKED on T6 (SDK loop is the image's main workload)
              └── BLOCKED on T7 (claim protocol runs before SDK loop)
              └── BLOCKED on T8 (bootstrap is the image's entrypoint)
              │
              T10: Produce orchestration templates (k8s CronJob + alternatives)
                  └── BLOCKED on T9 (image contract must be stable before templates reference env / volumes)
                  │
                  T11: End-to-end bootstrap scripts, integration tests, and operator docs
                      └── BLOCKED on T9 (docs + integration tests walk through the image)
                      └── BLOCKED on T10 (docs reference k8s / compose / systemd templates)
```

Notes on the diagram:
- **Wave 1 (T1, T2, T4)** are fully independent and can all start the moment tasks are approved. T1 is pure markdown; T2 and T4 are TypeScript but don't depend on each other.
- **T3 is a singleton bridge.** It depends on T1 (so the workflow repo's task schema matches what T3 writes into this feature's YAMLs) and it unlocks the four runtime tasks in Wave 3. T3 now also covers `workspace.yaml` `model_policy` schema and the `### Model overrides` parser contract.
- **Wave 3 (T5, T6, T7, T8)** opens as soon as T1/T2/T3 land. These run in parallel — they each consume the frozen schemas and agent.yaml shape but don't depend on each other. T6 now handles model policy resolution (reading `workspace.yaml` defaults + `tasks.md` overrides).
- **T9 is a strict gate.** The Docker image consolidates all runtime pieces (T4–T8) and must wait for every one of them to be green in isolation before image integration.
- **T10 and T11 are sequential** after T9. T10 produces orchestration templates; T11 produces operator docs + integration tests that reference both the image and the templates.
- **Old T11 (Opus approval wiring) is removed.** Model approval is now implicit — the human reviews `### Model overrides` in `tasks.md` during task review or edits it after escalation. No separate approval ceremony or start-implementation flag is needed. Escalation handling is documented in T11's operator docs.

Single-owner (sequential) areas where parallelization gives no gain:
- The SDK loop (T6) should have one author for coherence — don't split across multiple contributors.
- Operator docs (T11) — one narrative voice.

## Open questions deferred to task-breakdown stage

These are implementation-level details that will surface during task writing, not product or architectural decisions:

1. Exact test strategy for the two-agent race (real git server vs local bare repo).
2. CI pipeline for the Docker image (GHCR setup, tag convention).
3. Where the image keeps Claude Code's auth cache (needs to be per-agent).
4. Whether `suggested_next_step` goes in the task YAML `log` entry or in a separate `blocked_details` field.

## Workflow ripple — shared-rule & skill changes this design implies

These changes touch the workflow repo itself, not the agent code. They are **applied only after this technical design is re-approved** — the current stage reset exists to get agreement here first.

| # | File / artifact | Change |
|---|---|---|
| W1 | `workflow/CLAUDE.shared.md` | Remove the "Role skill overrides" section entirely. Replace with a short "Per-task required skills" note pointing readers to `tasks.md`'s `### Required skills` subsection as the source of capability. |
| W2 | `workflow/CLAUDE.shared.md` | Add a top-level rule: "Task YAML files contain only machine-mutable state (status, deps, branch, log). Logical intent — description, subtasks, required skills — lives in `tasks.md`." (Formalizes the split we already adopted for subtasks; now extends to required skills.) |
| W3 | `workflow/workflow_skills/tech-lead/SKILL.md` | Add rule: every `## T<n>` in a generated `tasks.md` must include a `### Required skills` subsection (empty is fine). Skill slugs must match directories under `workflow/technical_skills/`. |
| W4 | `workflow/workflow_skills/tech-lead/SKILL.md` | Remove references to `role` in task YAML schema. Update the "Required task fields" list to drop `role`. Update the parallelization-diagram example to stop annotating tasks with `(role)` — annotate with required-skills count or leave bare, tech-lead's choice. |
| W5 | `workflow/schemas/task.yaml.example` | Remove the `role:` field from the example. Keep everything else. |
| W6 | `workspace.yaml` (this workspace + any future workspaces) | Remove `role_skill_overrides`. Remove `roles:` list (previously `product_owner` / `tech_lead` — the user noted these will come back later with a permission model). |
| W7 | `workflow/workflow_skills/init-workspace/SKILL.md` and templates | Stop emitting `role_skill_overrides` and workspace-level `roles:` list. |
| W8 | `workflow/workflow_skills/init-feature/SKILL.md` and templates | Update the task template to omit `role:`. Update the tasks.md template to include an empty `### Required skills` section stub per task. |
| W9 | `workflow/workflow_skills/start-implementation/SKILL.md` | Remove any role-based validation. Remove any `--model-override` flag or `model_override` field handling — model selection is now driven by `workspace.yaml` `model_policy` + `tasks.md` `### Model overrides`, not by start-implementation flags. |
| W10 | Existing task YAMLs under `docs/features/distributed-agent-team/tasks/` | Once this design is re-approved and tasks are regenerated, remove `role:` from each. Existing tasks in other features (none in this workspace) remain untouched — additive removal. |
| W11 | `docs/features/distributed-agent-team/tasks.md` | Add `### Required skills` subsection to each `## T<n>`. Tech-lead fills in the minimal set per task. |
| W12 | `workflow/workflow_skills/tech-lead/SKILL.md` | Add rule for optional `### Model overrides` subsection per task in `tasks.md`. Document the grammar: phase name (`implementation`, `self_review`, `pr_description`, `suggested_next_step`), `allowed` list, `default` value. If absent, workspace defaults apply. |
| W13 | `workflow/templates/workspace/workspace.yaml` | Add `model_policy` section with per-phase `allowed` + `default` structure. Document that this is the centralized model cost-control surface. |

These are tracked here so nothing drops on the floor. T1 covers W1–W5, W7–W9, W12–W13. T3 covers W6, W10 + the schema code work. W11 was already applied during task generation.
