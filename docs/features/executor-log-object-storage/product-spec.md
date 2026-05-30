# Product Specification

## Feature
- Feature ID: `executor-log-object-storage`
- Title: Executor Log Object Storage — persist run logs to S3/MinIO with per-run links

> Status: **draft** — pending human review. Split out of `standalone-executor-hardening` (same branch) to keep that feature focused on the dispatcher + decoupling.

## Problem

`standalone-executor-hardening` takes the executor's logs *off* the management repo on the `local-docker` (standalone) path: the git flush is disabled (`LOG_SINK=none`) and the executor logs to **stdout** only. That achieves decoupling, but it leaves `local-docker` run logs **ephemeral** — visible only via `docker logs` / the dispatcher's captured stdout, gone once the container is reaped, and not RAG-indexed.

For `local-docker` to be usable for real review cycles — and to mirror production log durability — each run's log needs **durable, addressable storage**. The executor (the only component that has the log) should upload its run log to S3-compatible object storage and return a link; the orchestrator records the per-run link as task metadata so humans, reviewers, and RAG can find it later.

## Goals

- Add an **`S3LogSink`** behind the executor's `LogSinkPort` (introduced by `standalone-executor-hardening`): the executor uploads its run log to S3-compatible storage — **MinIO in dev, S3 in prod**.
- Return the **per-run log link in `result.json`** (additive ABI change: `log_url`).
- The orchestrator **persists the per-run link** as task metadata — a **list** (`runs: [{ run_kind, handle, log_url, at }]`), since a task has multiple runs (impl, fix, review). Git task YAML today; a Postgres table under `workflow-db` later.
- The **dispatcher injects** the object-store endpoint + credentials at spawn (it is already the sole credential holder after `standalone-executor-hardening`).
- Logs survive container teardown and are addressable; RAG can index them.

## Non-goals

- **Not the dispatcher / decoupling architecture** — that is `standalone-executor-hardening` (this feature's dependency).
- Not a log-viewing UI, search, or analytics surface.
- Not the production k8s deployment (the S3 adapter is substrate-agnostic; prod rollout rides the k8s feature).
- Not changing what the executor logs — only where the log is persisted.

## Relationship to other features

- **Depends on `standalone-executor-hardening`** — uses its `LogSinkPort` seam (the `LOG_SINK` config), the dispatcher credential-injection path, and the `local-docker` topology.
- Feeds `workflow-db` — the per-run `runs[]` schema designed here becomes a Postgres table when workflow state moves to the database.

## Key open questions (to resolve in technical design)

1. **Object-key scheme** — e.g. `logs/<workspace_id>/<feature_id>/<task_id>/<handle>.jsonl`. Confirm and document.
2. **Upload mode** — single upload at end-of-run vs streaming/multipart during the run (matters for long tasks and for crash visibility).
3. **Failure handling** — if upload fails, return `log_url: null` plus a stderr tail (today's crash-tail behaviour); result delivery stays authoritative.
4. **Retention / lifecycle** — dev MinIO (none / short) vs prod S3 lifecycle policy.
5. **RAG indexing** — should object-store logs be indexed (source_type `task_log`)? If so, how does the indexer reach them.
6. **Bundled path** — does `local-subprocess` also move to S3, or keep git logging? (Default: keep git for the untouched bundled path.)
7. **Credentials** — exact object-store credential scoping/injection via the dispatcher (dev env vs prod Secret references), aligned with `executor-credential-isolation`.

## Success criteria

- Each `local-docker` run's log is uploaded to object storage (MinIO dev / S3 prod) and addressable via the `result.json` `log_url`.
- The orchestrator stores the per-run link list on the task; it survives container teardown.
- Upload failure degrades gracefully (`log_url: null` + tail), never blocking result delivery.
- No change to what the executor logs or to agent behaviour.
