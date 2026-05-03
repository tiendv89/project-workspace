# Product Specification

## Feature
- Feature ID: `platform-byo-executor`
- Title: Bring-Your-Own-Executor — customer-supplied executor images on the platform

## Problem

Today the agent runtime ships as a single image: orchestrator and Claude executor are built and released together, deployed by whoever runs the platform. This works for a single-team setup but does not scale to a platform play where multiple customers each want to run their own executor — different model providers, custom prompts, internal skills, proprietary tooling — without giving the platform their source code.

The platform needs a way to let a customer **register their own executor image**, **prove it conforms to the runtime ABI**, and have the platform **provision the runtime infrastructure** so that an orchestrator pod (platform-owned, workflow-aware) can spawn the customer's executor pod (customer-owned, opaque) per task.

## Goals

- Allow a customer to register an executor image (registry URL, version, pull credentials) against their workspace.
- Run a conformance test suite against the registered image and gate activation on success.
- Provision per-tenant runtime infrastructure where the orchestrator pod can launch and communicate with the customer's executor pod via the existing ABI.
- Enforce tenant isolation — namespace, network policy, secrets — so executor pods cannot see other tenants' data.
- Mint scoped credentials (GitHub token, SSH key) for the executor pod's lifetime; do not share platform-wide credentials with customer-controlled code.
- Track per-tenant resource usage for metering and billing.
- Provide the customer a self-service surface to view their own runs, logs, and conformance results.

## Non-goals

- Building the executor SDK or reference executor — those exist (`@workflow/runtime-abi`, `runtime/executors/claude/`).
- Running customer code on shared infrastructure — every executor invocation runs in tenant-isolated infrastructure.
- Supporting non-containerised executors — the platform contract is a container image.
- Replacing the existing claim-via-git protocol — workflow state remains in git; this feature only changes who runs the executor.

## Open questions

The shape of the system depends on how each of these is resolved. They are listed here for spec-stage discussion, not yet decided.

### Q1 — Pod lifecycle
Are executor pods **ephemeral** (one pod per task, spun up at claim time, torn down at exit) or **long-running** (one pod per tenant, reused across tasks)?
- Ephemeral: clean isolation, simple lifecycle, slow per-task spawn cost.
- Long-running: fast spawn, idle cost, complex restart/upgrade semantics.

### Q2 — Conformance test
What does "passing conformance" mean?
- A fixed synthetic task suite the platform owns and runs?
- Customer-supplied test fixtures?
- Both — platform suite for ABI compliance, customer suite for functional smoke tests?

### Q3 — Workspace repo ownership
Where does the customer's management repo (workspace.yaml, task YAMLs) live?
- On the customer's own GitHub org (platform reads via app/PAT)?
- Mirrored / hosted by the platform?
- Either, configurable per workspace?

### Q4 — Credential model
How does the executor pod get GitHub credentials for `git push` and `pr-create`?
- Customer provides a long-lived PAT in their workspace `.env`?
- Platform integrates as a GitHub App and mints per-task scoped tokens?
- Per-task installation tokens issued to the executor's lifetime only?

### Q5 — Network model
How are orchestrator and executor pods connected?
- Same K8s pod, sidecar containers (low latency, shared lifecycle)?
- Same namespace, separate pods, K8s Service for IPC (cleaner separation)?
- Different namespaces with NetworkPolicy (strongest isolation, more setup)?
- Queue-based decoupling (orchestrator publishes, executor consumes — no direct connection)?

### Q6 — Versioning under load
A customer pushes executor v2 while v1 has in-flight tasks. What happens?
- New tasks start on v2; running tasks finish on v1 (drain semantics)?
- All tasks killed and re-claimed on v2 (cutover semantics)?
- Pinned per-task at claim time, immutable after (snapshot semantics)?

### Q7 — Multi-executor per tenant
Can a tenant register multiple executor images and route different task types to different executors? E.g., Claude executor for code tasks, custom Python executor for data tasks.

### Q8 — Billing unit
What does the platform meter and charge for?
- Per task completed?
- Per executor-minute (compute time)?
- Per orchestrator-poll (workflow management)?
- Some combination?

### Q9 — Failure attribution
When a task fails, the platform must distinguish:
- Customer executor bug (their code crashed, hung, returned invalid result.json)
- Platform infrastructure issue (orchestrator crashed, network error, image pull failure)
- Customer workflow problem (bad task spec, missing dependency)

This shapes SLA, billing dispute resolution, and observability requirements.

### Q10 — ABI versioning and compatibility
The runtime ABI evolves. Customer-registered images may speak older versions. How does the platform negotiate?
- Image declares version via probe / manifest?
- Platform supports N concurrent ABI versions?
- Forced upgrades on breaking changes?
