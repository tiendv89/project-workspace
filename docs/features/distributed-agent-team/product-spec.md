# Product Specification

## Feature
- Feature ID: `distributed-agent-team`
- Title: Distributed agent team (self-activating agents pulling work from workspace)

## Problem

The workflow already supports declaring `execution.actor_type: agent` on tasks, but there is no mechanism that actually gets agents working. Today, a human must manually run `start-implementation` for every task — the `agent` designation is just documentation.

We want agents to behave like distributed team members: each one running in its own environment, watching the shared workspace, pulling work it is qualified for, doing the work, and submitting it for human review. No central orchestrator, no human dispatcher.

## Goals

1. **Self-activation** — agents do not need a human or central system to tell them to start; they wake themselves up, check workspace state, and begin work when eligible.
2. **Decentralized team model** — each agent runs in its own environment (VM, container, local machine, CI runner) with its own folder and full permissions inside that folder. Agents do not know about each other; they only know about the shared workspace.
3. **Skill/role-aware pickup** — an agent only claims tasks that match its declared roles and skills. A backend agent does not pick up frontend tasks.
4. **Safe concurrent operation** — when multiple agents are online, two agents must not claim the same task. The claim protocol must be safe under concurrency.
5. **Agent workspace lifecycle** — there is a first-class concept of an "agent workspace" (analogous to a project workspace) with its own bootstrap, identity, and local state.
6. **Observable to humans** — humans can see which agent claimed which task, when, and what it did, through the existing task `log` and `status.yaml` history.

## Non-goals

- Not building a central orchestrator or scheduler.
- Not replacing human review — agents still only move tasks to `in_review`, not `done`.
- Not pinning down LLM implementation details (which model, prompting strategy, internal tool-use loop). The spec defines **what** an agent must do during execution; technical design picks **how**.
- Not building an agent-to-agent communication channel. Agents coordinate only through workspace state (tasks, git).
- Not handling remote agent provisioning/infrastructure (that is an operator concern, not a workflow concern).

## User stories

### US-1 — Human plans a feature, agents do the work
As a tech lead, after I approve the task breakdown for a feature, I want any online agent with matching skills to pick up ready tasks automatically, so I do not have to dispatch work manually.

### US-2 — Operator spins up a new agent
As an operator, I want to initialize a new agent workspace on any machine with a single command, declare its roles/skills, and have it join the team by pulling the shared workspace state. No central server registration.

### US-3 — Two agents safely share the queue
As an operator running two backend agents, I want to be confident that both will not attempt the same task — exactly one claims it and the other moves on.

### US-4 — Human audits who did what
As a tech lead reviewing a completed task, I want to see which agent claimed it, when, what commits/PR it produced, and its log entries — all visible in the task YAML and workspace history.

### US-5 — Agent recognizes it cannot do a task
As an agent, if I encounter a task I am not qualified for (wrong role, missing skill, unmet dependency), I leave it alone. I do not claim it and do not error loudly.

### US-6 — One agent serves multiple projects
As an operator with limited capacity, I want one agent to watch multiple project workspaces so that a single backend agent can serve both `project-A` and `project-B` without running two processes.

### US-7 — Two eligible agents do not collide
As an operator running two backend agents with identical skills, when one new task becomes ready, exactly one of them claims it and the other moves on without error.

### US-8 — Finance can approve the spend
As an IT/finance stakeholder, I want to cap how much each agent can spend per month, see per-agent usage, and know that idle agents cost nothing, so I can approve the rollout with confidence.

### US-9 — Operator can kill an agent cleanly
As an operator, if an agent is misbehaving or I need to take it offline, I want to set a single flag (`enabled: false`) and have the agent stop claiming new work on its next activation — without killing the process or losing in-flight work.

## Core concepts

### Agent workspace
A dedicated folder on the agent's host containing:
- agent identity config (agent id, display name, declared roles, skills)
- a local clone of the shared workspace repo (read/write)
- a working area where the agent clones target repos and does work
- its own `.env` for runtime credentials (SSH key, GitHub token, etc.)

An agent workspace is created once per agent instance, via an `init-agent` skill.

### Agent identity
Each agent has:
- `agent_id` — stable unique string (e.g. `backend-bot-01`)
- `display_name` — human-readable
- `roles` — list of roles it can fulfill (e.g. `[backend_engineer]`)
- `skills` — list of technical skills it has (e.g. `[nestjs-best-practices, postgres-best-practices]`)
- `watches` — list of workspace repo URLs the agent watches (1+ projects)
- `host` — informational (where it runs)
- `enabled` — boolean kill switch; when `false`, activation cycles exit immediately
- `budget` — per-task limits (tokens and iterations); see Cost model and Execution contract

Agents identify themselves by `agent_id` in task logs. This is the only audit trail needed.

Credentials (API key, SSH key, GitHub token) are stored in the agent workspace's `.env`, **never** in `agent.yaml`.

### Multi-project agents
An agent can watch one or many project workspaces. Its `agent.yaml` declares `watches: [workspace_repo_url, ...]`. Each activation cycle iterates through every watched workspace, pulling latest state and scanning for eligible tasks.

- Single-project is just the `watches: [one_repo]` case — same model, no special path.
- Order of iteration is declaration order; a task found in the first eligible workspace stops the cycle (one task per activation).
- There is no per-project priority weighting in v1; ordering is the operator's lever.

### Activation
An agent "activates" by running its pull loop once:
1. Pull latest workspace repo
2. Scan for candidate tasks
3. Attempt to claim one (atomic)
4. Do the work if claim succeeded
5. Push result, exit the activation

How activation is *triggered* is outside this spec (cron, webhook, systemd timer, long-running loop) — the skill only defines the single activation cycle.

### Claim protocol
A claim is an atomic mutation to the task YAML:
- status: `ready` → `in_progress`
- `execution.last_updated_by`: set to `agent_id`
- `log`: append entry with action `claimed`, by `agent_id`, timestamp
- commit and push

If the push is rejected due to a conflict (another agent got there first), the agent drops the claim and moves to the next candidate. No locks, no leases — git is the source of truth.

### Agent execution contract (from claim to handoff)

After a successful claim, the agent performs a deterministic sequence. The LLM-powered part is only step 3 (Implementation) and step 4 (Self-review); every other step is mechanical.

1. **Setup**
   - Ensure the target repo (from task `repo` field) is cloned in the agent's workspace.
   - Resolve the base branch from the repo's `base_branch` entry in `workspace.yaml` (no default — an unset value is an error).
   - Pull latest from that base branch.
   - Create or check out the branch named in the task's `branch` field.

2. **Context gathering** (zero LLM calls — just file reads)
   - Read the task YAML.
   - Read the feature's `product-spec.md` and `technical-design.md`.
   - Load role-specific technical skills from `role_skill_overrides` / `technical_skills/`.
   - Load shared workflow rules from `CLAUDE.shared.md`.

3. **Implementation** (LLM-powered)
   - Agent designs and implements the task using the gathered context.
   - Writes code, runs tests/lint/type checks, iterates.
   - Token budget is enforced throughout — see Cost model.
   - **Iteration cap**: a single task must not exceed `budget.max_iterations` implementation attempts (default: 3; configurable per-agent and per-task). An "iteration" is one full cycle of implement → run checks → observe result. If the cap is reached without success, the agent exits to error path 7b.

4. **Self-review** (LLM-powered)
   - Runs the existing `pr-self-review` skill against the working branch.
   - If review surfaces blocking issues the agent cannot resolve, abort to step 7b.

5. **PR creation** (mechanical + one LLM call for PR description)
   - Commits with message referencing the feature/task id.
   - Pushes the branch.
   - Runs the existing `pr-create` skill.
   - Writes PR URL back to the task YAML's `pr.url` and `pr.status`.

6. **Handoff**
   - Updates task status: `in_progress` → `in_review`.
   - Appends a log entry with action `submitted_for_review`, `by: <agent_id>`, tokens consumed, summary.
   - Commits + pushes the task update to the workspace repo.
   - Exits cleanly (container exit code 0).

7. **Error paths** (each is a terminal state for this activation cycle)
   - **7a — Budget exceeded**: set task `status: blocked`, `blocked_reason: budget_exceeded`, log token overrun, commit + push, exit.
   - **7b — Cannot make progress** (iteration cap hit, tests fail repeatedly, ambiguous spec, self-review blocks): set `status: blocked`, `blocked_reason: <specific reason>`, log what was tried, and include an LLM-generated `suggested_next_step` for the human (one small, budget-bounded call). Commit + push, exit.
   - **7c — Skill / tool unavailable in environment**: set `status: blocked`, `blocked_reason: environment_gap`, exit. (Should be prevented by eligibility matching, but defended against.)
   - **7d — Git push rejected on final update**: pull, rebase task file, retry once. If still failing, log and exit with the task left in `in_progress` (requires human resolution in v1; heartbeat-based recovery deferred).
   - **7e — Uncaught failure / crash**: task stays `in_progress`. v1 requires human reset; v2 adds heartbeat timeout.

### Agents never mutate

Reinforces the review boundary — agents cannot:
- Mark a task `done` (human-only).
- Approve or reject any workflow stage.
- Modify `status.yaml` stage review fields.
- Edit another agent's log entries.

### Contention between eligible agents
When multiple agents are eligible for the same task (e.g. two backend agents of the same skill set), the system must choose one without a central authority. Key observation: **an agent doing a task is not in the pull loop** — it is executing, not competing. So contention only happens between *idle* agents.

Among idle agents, v1 uses **jittered first-claim-wins**:
1. Each agent computes a random jitter `sleep(random(0, N)s)` before attempting its claim.
2. First successful git push wins; losers see a push-rejection and drop.
3. Losers move to the next eligible task or exit the cycle.

This is fair-ish without requiring agents to know about each other. It is NOT load-balanced — a lucky agent can claim multiple tasks in a row.

**Deferred to v2 — load-aware fairness**: each agent writes a heartbeat file at `workspace/agents/<agent_id>.yaml` containing `{status, current_task, claims_last_hour}`. Idle agents read peers' files and scale their jitter proportional to their own recent claim rate. Still decentralized, just more fair.

### Eligibility
A task is eligible for an agent A when:
- `status == ready`
- `execution.actor_type in {agent, either}`
- `role` in `A.roles`
- All `depends_on` tasks are `done`
- All skills required by the task's role (via `role_skill_overrides`) are a subset of `A.skills`

**Eligibility is deterministic, pure-code logic — no LLM call.** This is a hard architectural rule. See Cost model.

## Runtime & DevX model

### Distribution: Docker-first, bare-metal as fallback

**v1 ships a Docker image** as the primary runtime. An agent is a container; multiple agents on one host are multiple containers.

Why Docker:
- Delivers the "any runner" goal directly — any host with Docker can host an agent.
- Bundles Claude Code + git + required tools inside the image; no "what version of X is on the host" drift.
- Native multi-agent isolation (containers + volumes).
- Standard ops UX: `docker ps`, `docker logs`, `docker restart`, restart policies.
- Forces headless auth (`ANTHROPIC_API_KEY`) from day one.

Bare-metal operation is documented as a second-class fallback (same `agent-activate` skill, invoked by cron/systemd) for environments without Docker. Not a v1 acceptance target, but explicitly possible.

### Per-agent folder rule (load-bearing)

Every agent owns exactly one folder on its host. Nothing is shared between agents on the same host.

```
~/agents/
  backend-bot-01/
    agent.yaml            # identity, roles, skills, watches, enabled, budget
    .env                  # ANTHROPIC_API_KEY, SSH key path, GH_TOKEN
    docker-compose.yml    # generated by init-agent
    data/                 # mounted into container at /agent
      workspaces/         # one clone per watched workspace
      repos/              # target repo clones
      log.jsonl           # structured activity log
  backend-bot-02/
    ...                   # fully separate, nothing shared
```

Consequences (accepted):
- Workspace clones and target repo clones are duplicated across agents on the same host — disk cost, not a correctness problem.
- Moving an agent to another host = copy the folder.
- Deleting an agent = delete its folder.

### Operator UX

```bash
# Bootstrap a new agent (one-time)
claude skill init-agent
# prompts: agent_id, roles, skills, watches, budget
# writes: ~/agents/<agent_id>/{agent.yaml, .env, docker-compose.yml, data/}
# prints: next steps (edit .env to add API key, then docker compose up -d)

# Run
cd ~/agents/<agent_id>
docker compose up -d

# Observe
docker compose logs -f
claude skill agent-status       # parses agent.yaml + log.jsonl, prints health summary
claude skill agent-activate --dry-run   # shows which task would be claimed, no side effects

# Disable without killing
# edit agent.yaml: enabled: false — agent exits cleanly on next cycle

# Upgrade
docker compose pull && docker compose up -d
```

### v1 DevX acceptance criteria

1. `init-agent` is interactive, runs in under 2 minutes, and leaves a fully-ready agent workspace.
2. `docker compose up -d` in the agent folder starts an agent that joins the team within one activation cycle.
3. `agent-status` gives a complete health snapshot in one command (config, last activation, last claimed task, errors, token usage).
4. `agent-activate --dry-run` is available and safe (no git writes, no LLM calls).
5. Setting `enabled: false` in `agent.yaml` stops new claims on the next cycle without killing the container.
6. Each agent folder is fully self-contained — copying the folder to another host (with Docker) resumes operation.

## Cost model

Agents are long-lived and run unattended. Cost must be predictable, auditable, and capped.

### Hard rules (v1)

1. **Idle polling burns zero tokens.** Eligibility matching, git pulls, and claim attempts are pure code. An LLM is invoked **only after** a task has been successfully claimed and the agent enters the "do the work" phase. An idle agent polling every 5 minutes with no eligible tasks costs $0/month in API spend.
2. **One API key per agent.** Each agent has its own `ANTHROPIC_API_KEY`. No key sharing across agents. Enables per-agent audit, per-agent rate-limiting, and scoped blast radius if a key leaks.
3. **Per-task token budget.** `agent.yaml` declares a default `budget.max_tokens_per_task`; individual tasks may override via a `budget` field in the task YAML. Exceeding the budget causes the agent to abort, mark the task `blocked` with `blocked_reason: budget_exceeded`, and stop — humans decide next steps.
4. **Usage logging per task.** Every task `log` entry for a work phase records tokens consumed (input, output, total) and approximate USD cost. Humans can trace cost-per-task and cost-per-feature after the fact.
5. **Kill switch.** `agent.yaml.enabled = false` causes the agent to exit activation cycles immediately without claiming work. The operator can disable an agent without touching infrastructure.

### Defense in depth

- **Workspace-level budget cap** (Anthropic Console): hard backstop set per org workspace. Independent of agent logic.
- **Per-agent key**: allows revoking one agent without affecting others.
- **Abort on budget exceed**: the agent's own code refuses to continue past the declared budget.
- **Kill switch in workspace repo**: flipping `enabled: false` in `agent.yaml` takes effect on next pull, in seconds — no ops access needed.

### Cost acceptance criteria

1. An idle agent (no eligible tasks) consumes **zero** Anthropic API tokens per activation cycle. Verified by log inspection showing zero LLM calls on idle cycles.
2. Each task log entry includes token usage for that task's work phase.
3. A task whose work would exceed `budget.max_tokens_per_task` is aborted and marked `blocked` with a clear reason; no overshoot is silently absorbed.
4. Setting `enabled: false` in `agent.yaml` prevents new task claims within one activation cycle.
5. Each agent uses a distinct `ANTHROPIC_API_KEY`; `init-agent` refuses to proceed without one configured.

## Open design questions (to decide in technical design)

Product-level decisions are now locked in the sections above. Remaining questions are implementation-level, to be resolved during technical design:

1. **LLM model selection**: which Claude model(s) for each execution step (planning, implementation, self-review, PR description)? Cost-aware routing?
2. **Tool-use architecture**: how the agent's inner loop is built (Claude Code skills, custom tool harness, Agent SDK)?
3. **Implementation iteration strategy**: how the agent decides when to stop iterating (test pass? self-review signal? iteration cap?).
4. **Claim race hardening**: is git push rejection enough in practice, or do we need a short lease file to protect against near-simultaneous pushes with pre-pull staleness?
5. **Activation trigger mechanism**: container restart policy, cron inside container, supervisor loop — which is cleanest?
6. **Skill sync at startup**: if `init-agent` declares a skill the image doesn't bundle, does the container refuse to start, fetch at runtime, or degrade? (Leaning: refuse to start — fail-fast.)
7. **Structured log format** (`log.jsonl`): field schema for activation events, task progress, token usage.

## Success criteria

- An operator can run `init-agent` + `docker compose up -d` on a fresh machine and have the agent join the team in under 5 minutes.
- With two agents of matching roles online, ten ready tasks are distributed between them without collision (jitter + git claim suffices).
- An agent configured with `watches: [project-A, project-B]` picks up eligible tasks from either project.
- Every `done` task has a complete audit trail showing which agent claimed it, when, and token cost.
- An idle agent polling continuously for 24 hours with no eligible tasks consumes zero Anthropic API tokens.
- Setting `enabled: false` in `agent.yaml` stops an agent from claiming new work within one activation cycle.
- The workflow continues to function for all-human projects — agents are additive, not required.

## v1 scope

**Skills:**
- `init-agent` — bootstrap an agent workspace (interactive, generates folder + config + compose file)
- `agent-activate` — run one activation cycle (pull → pick → claim → work → push); supports `--dry-run`
- `agent-status` — print health snapshot (config, last activation, last claim, errors, token usage)

**Config & data model:**
- `agent.yaml` — identity, roles, skills, watches, enabled flag, per-task budget
- Agent workspace folder layout per the Runtime & DevX section
- Per-agent folder ownership rule (no shared state between agents on one host)

**Runtime:**
- Docker image as primary distribution (bare-metal documented as fallback)
- Multi-project support via `watches` list
- Eligibility matching based on role + skills + dependencies
- Git-based claim protocol with jittered first-claim-wins
- No pre-registration — agents self-introduce via `agent_id` in task logs

**Cost controls:**
- One API key per agent (enforced at `init-agent` time)
- Zero-token idle polling (pure-code eligibility matching)
- Per-task token budget with abort-and-block behavior
- Per-task token usage logged in task YAML
- Kill switch via `agent.yaml.enabled`

**Deferred to later versions:**
- Heartbeat files (`workspace/agents/<agent_id>.yaml`) for load-aware fairness
- Webhook-triggered activation
- Pre-registration / agent dashboards
- Per-project priority weighting in `watches`
- Crash-recovery via heartbeat timeouts
- Model routing (Haiku for light work, Sonnet for heavy) as a cost optimization
- Fleet-wide observability (aggregated across agents)
