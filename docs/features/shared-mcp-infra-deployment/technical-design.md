# Technical Design

## Feature
- Feature ID: `shared-mcp-infra-deployment`
- Title: Shared MCP Services Deployment (RAG + GitNexus)

## 1. Current state

### MCP services today
Two MCP stacks ship with the agent runtime and are spun up **per-workspace** by `agent-workflow/runtime/orchestrator/templates/docker-compose.yml` (and the parallel `docker-compose.local-docker.yml`):

- **RAG stack** — `qdrant`, `rag-server` (port `8000`), `indexer`. Built from `RAG_SERVICE_LOCAL_PATH`. Storage in `qdrant_data` named volume.
- **GitNexus stack** — `gitnexus-indexer`, `gitnexus-server` (port `8002`). Built from `GIT_NEXUS_LOCAL_PATH`. Storage in `gitnexus-data` volume shared between the two containers.

Agents reach both via service-name DNS on the `agents-net` bridge: `MCP_RAG_URL` defaults to `http://rag-server:8000`; `GITNEXUS_MCP_URL` is opt-in.

### Isolation model today
The runtime partitions per-workspace by **collection name = `WORKSPACE_ID`** for RAG: indexer reads exactly one `workspace.yaml`, writes vectors to a Qdrant collection keyed by `WORKSPACE_ID`; rag-server reads the same collection. GitNexus takes a single `WORKSPACE_URL` and writes its call-graph to a workspace-scoped `gitnexus-data` volume.

### Target deployment infrastructure
Kitelabs runs production on a GKE cluster (GCP project `production-476602`) using three coordinating repositories:

| Repo | Purpose | Pattern |
|---|---|---|
| `infrastructures` (`github.com/kitelabs-io/infrastructures`) | GCP foundation (Terraform/Terragrunt) + ArgoCD apps for **cluster-scope** backing services (postgres, redis, mongodb, mysql, vault, grafana, loki, ingress-nginx) | `apps/gcp/environments/production/<service>/<scope>/{app.yaml,values.yaml}` — multi-source ArgoCD `Application` pulling a public Helm chart with values from this repo |
| `kitelabs-application` | Per-application Helm charts: `application/<service>/{api,worker}/{Chart.yaml,values.yaml}`. All depend on shared `base-service 0.1.6` chart. | Image pulled from `asia.gcr.io/production-476602/<service>:<tag>`. Tag pattern `main-<7char-sha>` for auto-update. |
| `kitelabs-application-infra` | ArgoCD `Application` + `AppProject` + `configmap.yaml` per app at `application/<service>/{api,worker}/`. | `argocd-image-updater` annotations: detects new `main-<sha>` images, writes the tag back to `kitelabs-application`. Auto-sync + selfHeal + prune. |

Existing precedents for workspace-related services already deployed under this pattern: `workflow-backend`, `workspace-github-adapter` (api + worker), `digital-factory-ui`, `workflow-user-service`. Ingress via `nginx-ingress` on `*.kitelabs.io` hostnames. Cluster-scope shared data services (sibling precedent for Qdrant): `postgresql`, `redis`, `mongodb`, `mysql` each under `infrastructures/apps/gcp/environments/production/<service>/shared/`.

### What "shared" means here
Move the five MCP services into the cluster so any number of agent-runtime instances point at a single endpoint set and consume one corpus per workspace. Deployment uses the same Helm/ArgoCD/image-updater mechanism every other app on the cluster uses; no bespoke "shared host" pattern.

## 2. Problem framing

What must change:
- The five MCP services (`qdrant`, `rag-server`, `indexer`, `gitnexus-server`, `gitnexus-indexer`) must run in the GKE cluster and serve traffic from agent runtimes anywhere.
- Agent-runtime stacks point at the cluster's MCP endpoints via env config (`MCP_RAG_URL`, `GITNEXUS_MCP_URL`).

What must stay stable:
- The MCP **URL contract** consumed by agents — already abstracted behind env vars.
- The **isolation guarantee** — workspace A must never read workspace B's indexed content.
- The **local-only developer flow** — a developer running offline still needs a full local stack. Shared-cluster mode is opt-in per workspace.

Fixed assumptions:
- The shared MCP **servers** (rag-server, gitnexus-server, gitnexus-indexer) run in the existing GKE cluster (`production-476602`). Follow the existing Helm/ArgoCD patterns; do not invent a new deployment shape.
- **Qdrant is consumed as a managed external service (Qdrant Cloud)** — same pattern as swell's voyager stack (`DB_QDRANT_HOST` + `DB_QDRANT_API_KEY` resolved from Vault into K8s Secret). No in-cluster Qdrant deployment, no PVC, no operator ownership of the vector store. Trade-off: monthly Qdrant Cloud cost vs. zero in-cluster ops surface for a stateful service.
- **No auth in v1** for the MCP endpoints themselves (rag-server, gitnexus-server). Cluster network boundary + DNS obscurity + optional nginx-ingress IP allowlist are the only defenses. Qdrant Cloud is reached via its own API key — that key is a deployment secret, not user-facing auth.
- Public HTTPS ingress via nginx-ingress on `kitelabs.io` subdomains for both MCP servers.
- Cluster-side artifacts (Helm charts, ArgoCD apps, K8s Secret templates) are produced as deliverable files under this feature folder, plus a tutorial. The operator pastes them manually into `kitelabs-application` and `kitelabs-application-infra` — **neither is registered in `workspace.yaml`** and neither receives task PRs from this feature. (`infrastructures` is no longer touched at all in this design, since Qdrant is external.)

## 3. Where the indexers live

The one meaningful design question is whether the indexers run **per-workspace** (locally, pushing to cluster/cloud backends) or **in the cluster** (multi-workspace, iterating over a workspace manifest).

**RAG**: with Qdrant Cloud as the vector store, the per-workspace RAG indexer **can reach Qdrant directly** over the public Internet using its own `QDRANT_URL` + `QDRANT_API_KEY`. No VPN, no IAP, no aggregated credentials needed. The existing single-workspace indexer keeps working as-is once it gains `QDRANT_API_KEY` env support (a trivial code addition — today the client is built with `QdrantClient(url=...)` and no api_key parameter). Per-workspace credential scoping (each workspace owns its own SSH key + `GITHUB_TOKEN`) is preserved.

**GitNexus**: the indexer and server **share a local data tree** (`/gitnexus-data/`) populated by `gitnexus analyze`. Splitting them across a network requires inventing a transport layer (NFS, rsync, write API) — none exist today. The pragmatic path is to keep them co-located, which means moving both into the cluster and accepting multi-workspace input via a ConfigMap manifest.

This gives a **hybrid**: RAG indexer stays per-workspace; GitNexus indexer + server both move to the cluster with a workspace manifest. This is the same Option C in the original draft, now viable again because Qdrant Cloud lifted the "internal-only Qdrant" constraint.

Trade-offs:
- RAG: zero application refactor beyond the `QDRANT_API_KEY` addition. Per-workspace failure isolation. Per-workspace SSH/GitHub credentials stay local.
- GitNexus: one indexer pod aggregates credentials for every registered workspace. Failure blast radius affects all workspaces (acceptable for v1; GitNexus is opt-in per workspace anyway).
- Two mental models — operators need to know "RAG indexer lives in the workspace runtime, GitNexus indexer lives in the cluster". Acceptable.

## 4. Chosen design

### Topology
```
┌─ Qdrant Cloud (managed) ────────────────────────────────────────────────┐
│  qdrant cluster — reached via QDRANT_URL + QDRANT_API_KEY                │
│  Collections: one per workspace_id                                       │
└──────────────────────────────────────────────────────────────────────────┘
        ▲                                       ▲
        │ from in-cluster rag-server            │ from per-workspace rag-indexer
        │ (Vault-backed K8s Secret)             │ (workspace .env)
        │                                       │
┌─ GKE cluster (production-476602) ────────────────────────────────────────┐
│                                                                          │
│  ── rag-service namespace ──                                             │
│  rag-server (Deployment, base-service chart) ─── ingress rag-mcp...     │
│      └─ reads X-Workspace-Id header → picks Qdrant collection            │
│                                                                          │
│  ── git-nexus namespace ──                                               │
│  gitnexus-indexer (Deployment) ──┐                                       │
│      └─ reads /etc/mcp/workspaces.yaml ConfigMap                         │
│                                  ├─ shared PVC gitnexus-data            │
│  gitnexus-server (Deployment) ───┘ ──────────── ingress gitnexus-mcp...  │
│      └─ reads X-Workspace-Id header → picks data subtree                 │
│                                                                          │
│  ── ingress-nginx ─ TLS terminated ─ no auth (optional IP allowlist) ──  │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
                            ▲                       ▲
                            │                       │
       MCP_RAG_URL=https://workflow-rag-mcp.kitelabs.io      │
       GITNEXUS_MCP_URL=https://workflow-gitnexus-mcp.kitelabs.io
                            │                       │
┌─ Per-workspace agent runtime (existing docker-compose.yml) ──────────────┐
│                                                                          │
│  agent-1/2/3  ── MCP_PROFILE=shared                                      │
│                ── forwards X-Workspace-Id header on MCP calls            │
│                                                                          │
│  rag-indexer  ── still runs locally per workspace                        │
│      └─ QDRANT_URL=https://xxx.qdrant.cloud:6333                         │
│      └─ QDRANT_API_KEY=<from .env, shared across workspaces or per-ws>   │
│      └─ writes to Qdrant collection = WORKSPACE_ID                       │
│                                                                          │
│  (rag-server, gitnexus-server, gitnexus-indexer NOT present locally      │
│   in shared mode — gated behind compose profiles:)                       │
└──────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Qdrant — managed external (Qdrant Cloud)
Not deployed by this feature.

- Operator provisions a Qdrant Cloud cluster (region near GKE for latency).
- Captures `QDRANT_URL` (e.g. `https://xxx-xxx.qdrant.cloud:6333`) and `QDRANT_API_KEY` in Vault under a path such as `/kv/data/kitelabs/mcp` (matches swell's `/kv/data/voyager/...` shape).
- A K8s Secret in the `rag-service` namespace pulls these values via ExternalSecret / Vault injector (the existing mechanism used in `kitelabs-application-infra/secrets/voyager/`). Manifest template produced as a deployment artifact.
- Collections: one per workspace, named after `workspace_id`. Created lazily by either rag-server or rag-indexer on first write — no upfront provisioning step.

### 4.2 rag-server — application Helm chart
Pattern matches `workspace-github-adapter/api`.

- Path (artifact): `kitelabs-application/application/rag-service/server/{Chart.yaml,values.yaml}`. Depends on `base-service 0.1.6`.
- Image: `asia.gcr.io/production-476602/rag-service:<tag>`. CI in `rag-service` repo builds & pushes `main-<sha>` images.
- Env wiring:
  - `QDRANT_URL` from `mcp-qdrant` K8s Secret (Vault-backed).
  - `QDRANT_API_KEY` from the same Secret.
- Reads `X-Workspace-Id` request header to select the Qdrant collection. Falls back to default-workspace behaviour when header is absent (backward-compat).
- Service port `8000`. Ingress at `workflow-rag-mcp.kitelabs.io` via nginx-ingress, TLS via cert-manager.
- **Stateless** — no PVC, no persistent storage in the cluster. Every request goes to Qdrant Cloud. Pod restarts are free.
- ArgoCD app (artifact): `kitelabs-application-infra/application/rag-service/server/app.yaml` + `app-project.yaml` + `configmap.yaml`. `argocd-image-updater` annotations matching the existing precedent.

### 4.3 rag-indexer — stays per-workspace
Continues to run in the per-workspace `docker-compose.yml`. No cluster deployment for the RAG indexer.

- When workspace's `.env` sets `MCP_PROFILE=shared`:
  - `QDRANT_URL` and `QDRANT_API_KEY` are read from the workspace `.env` (Qdrant Cloud URL + key).
  - All other indexer behaviour unchanged — single workspace.yaml, single Qdrant collection keyed by `WORKSPACE_ID`.
- Workspace-owned `SSH_PRIVATE_KEY` and `GITHUB_TOKEN` stay local — no aggregated credentials for RAG.
- **No cluster PVC.** The indexer's small PR-cursor state lives in the existing `pr_index_state` Docker named volume on the workspace host (unchanged from today).
- Small `rag-service` change required: `QdrantClient(url=...)` constructor calls in `services/indexer/main.py` (line 221) and `services/rag_server/server.py` (line 198) must accept an optional `api_key=os.environ.get("QDRANT_API_KEY")` parameter.

### 4.4 gitnexus-indexer + gitnexus-server — both in cluster, sharing a PVC
Both run in the `git-nexus` namespace, sharing a single `ReadWriteOnce` PVC (`gitnexus-data`).

- Paths (artifacts): `kitelabs-application/application/git-nexus/server/` and `kitelabs-application/application/git-nexus/indexer/`. Both depend on `base-service 0.1.6`.
- Images: `asia.gcr.io/production-476602/git-nexus:<tag>`. CI in `git-nexus` repo.
- Shared `PersistentVolumeClaim` named `gitnexus-data` (`pd-balanced`, 50Gi). Both Deployments mount it at `/gitnexus-data`.
- **Co-location constraint**: `pd-balanced` is `ReadWriteOnce` — both Deployments must schedule on the same node. Enforced via `podAffinity: requiredDuringSchedulingIgnoredDuringExecution` keyed on a pod label such as `gitnexus-data-consumer: "true"`. Both at replica count `1`. Switch to a `ReadWriteMany` class (Filestore) only if multi-node access becomes necessary — separate, out of v1 scope.
- gitnexus-indexer reads the same `/etc/mcp/workspaces.yaml` ConfigMap as rag-indexer; iterates and analyzes each workspace, writing under `/gitnexus-data/<workspace_id>/`.
- gitnexus-server adds `X-Workspace-Id` header routing with default fallback (backward-compat).
- Ingress at `workflow-gitnexus-mcp.kitelabs.io`. No auth.
- ArgoCD apps (artifacts): `kitelabs-application-infra/application/git-nexus/{server,indexer}/app.yaml` + `app-project.yaml` + `configmap.yaml`.

### 4.5 Per-workspace runtime — `MCP_PROFILE` gate
- New env var `MCP_PROFILE` in workspace runtime compose templates (`docker-compose.yml`, `docker-compose.local-docker.yml`).
- `MCP_PROFILE=local` (default) — existing behaviour. All five local services launch.
- `MCP_PROFILE=shared` — gate `qdrant`, `rag-server`, `gitnexus-indexer`, `gitnexus-server` behind a compose `profiles:` clause so they do not start. **`indexer` (RAG) keeps running locally** but with `QDRANT_URL` + `QDRANT_API_KEY` pointing at Qdrant Cloud. Agent base service picks up `MCP_RAG_URL=https://workflow-rag-mcp.kitelabs.io` and `GITNEXUS_MCP_URL=https://workflow-gitnexus-mcp.kitelabs.io` from `.env`.
- Agent MCP client forwards `X-Workspace-Id: <WORKSPACE_ID>` on every request.

### 4.5b Cluster storage footprint summary
| Service | Cluster PVC? | Notes |
|---|---|---|
| Qdrant | — | External (Qdrant Cloud); storage handled by vendor |
| rag-server | No | Stateless; every request hits Qdrant Cloud |
| rag-indexer | No | Runs per-workspace, not in cluster; uses workspace-local Docker volume |
| gitnexus-indexer | **Yes (shared)** | Writes call-graph under `/gitnexus-data/<workspace_id>/` |
| gitnexus-server | **Yes (shared)** | Reads same `/gitnexus-data/` tree |

Net cluster storage: **one PVC** (`gitnexus-data`, `pd-balanced`, 50Gi RWO, mounted on both git-nexus pods via `podAffinity`).

### 4.6 No auth in v1
- MCP servers (rag-server, gitnexus-server) accept any caller that can reach the ingress.
- Cluster network boundary + DNS obscurity + optional nginx-ingress IP allowlist are the only defenses. The allowlist is an nginx annotation in `values.yaml` (operator-tunable, not a code task).
- Adding bearer-token / per-workspace tokens / mTLS later does **not** require changes to the URL contract — agents already pass headers; we just add an `Authorization` header in a future feature.

### 4.7 Artifact delivery
All cluster-side files (`kitelabs-application`, `kitelabs-application-infra`) are produced as artifacts under this feature folder, not pushed to the deployment repos directly. `infrastructures` is not touched (Qdrant is external).

```
docs/features/shared-mcp-infra-deployment/
├── deployment-artifacts/
│   ├── kitelabs-application/
│   │   └── application/
│   │       ├── rag-service/
│   │       │   └── server/{Chart.yaml,values.yaml}
│   │       └── git-nexus/
│   │           ├── server/{Chart.yaml,values.yaml}
│   │           └── indexer/{Chart.yaml,values.yaml}
│   └── kitelabs-application-infra/
│       ├── application/
│       │   ├── rag-service/
│       │   │   ├── app-project.yaml
│       │   │   ├── configmap.yaml
│       │   │   └── server/app.yaml
│       │   └── git-nexus/
│       │       ├── app-project.yaml
│       │       ├── configmap.yaml
│       │       ├── server/app.yaml
│       │       └── indexer/app.yaml
│       └── secrets/
│           └── kitelabs/
│               └── mcp-qdrant-secret.yaml    # QDRANT_URL, QDRANT_API_KEY ← Vault
│               └── gitnexus-indexer-secret.yaml  # SSH_PRIVATE_KEY, GITHUB_TOKEN ← Vault
└── deployment-tutorial.md
```

The tutorial walks the operator through:
1. Provision a Qdrant Cloud cluster; store `QDRANT_URL` + `QDRANT_API_KEY` in Vault under `/kv/data/kitelabs/mcp`.
2. Provision a single dedicated SSH key + `GITHUB_TOKEN` with read access to every registered workspace's repos (for `gitnexus-indexer`); store in Vault.
3. Copy `deployment-artifacts/kitelabs-application/...` into `kitelabs-application` on a feature branch; open PR.
4. Copy `deployment-artifacts/kitelabs-application-infra/...` into `kitelabs-application-infra` on a feature branch; open PR.
5. Apply the K8s `ConfigMap` mapping registered workspaces (`/etc/mcp/workspaces.yaml` for `gitnexus-indexer`) — manifest provided.
6. Configure DNS (`workflow-rag-mcp.kitelabs.io`, `workflow-gitnexus-mcp.kitelabs.io`) and (optionally) the nginx-ingress IP allowlist.
7. Roll out per-workspace `MCP_PROFILE=shared` cutover; populate each workspace `.env` with `QDRANT_URL`, `QDRANT_API_KEY`, `MCP_RAG_URL`, `GITNEXUS_MCP_URL`.

## 5. Dependency analysis

### Internal dependencies (repos with task PRs)
| Repo | `workspace.yaml` id | Change |
|---|---|---|
| `workflow` (agent-workflow) | `workflow` | `MCP_PROFILE` flag in compose templates; agent MCP client forwards `X-Workspace-Id`; operator docs |
| `rag-service` | `rag-service` | rag-server `X-Workspace-Id` header routing with default fallback; small `QDRANT_API_KEY` env support in `QdrantClient(...)` constructors (both indexer and rag-server); CI to build & push `main-<sha>` to `asia.gcr.io/production-476602/rag-service` |
| `git-nexus` | `git-nexus` | Multi-workspace indexer (ConfigMap manifest); gitnexus-server `X-Workspace-Id` header routing with default fallback; CI to push `main-<sha>` to `asia.gcr.io/production-476602/git-nexus` |
| `management-repo` (this) | `management-repo` | Produce deployment artifacts (Section 4.7) + tutorial; `.env.template` additions for `MCP_PROFILE`, `MCP_RAG_URL`, `GITNEXUS_MCP_URL`, `QDRANT_URL`, `QDRANT_API_KEY` |

`kitelabs-application` and `kitelabs-application-infra` are **out of the task system**. They receive operator-driven PRs from the artifacts produced above. `infrastructures` is not touched at all.

### External dependencies
- **GKE cluster** `production-476602` — already operational.
- **GCR registry** `asia.gcr.io/production-476602/...` — image push credentials for `rag-service` and `git-nexus` CI must exist or be granted via the existing CI service account.
- **nginx-ingress + cert-manager** — already deployed cluster-wide.
- **DNS for `*.kitelabs.io`** — operator manages. New records: `workflow-rag-mcp.kitelabs.io`, `workflow-gitnexus-mcp.kitelabs.io`.
- **Qdrant Cloud** — managed cluster provisioned by the operator; URL + API key stored in Vault.
- **Vault** — already in cluster (used by swell precedent for `DB_QDRANT_HOST` etc); same `ExternalSecret` / sidecar mechanism reused here.

### Blocking decisions
- **D1** ✓ resolved — `X-Workspace-Id` header routing accepted on both rag-server and gitnexus-server, with `default` fallback when absent.
- **D2** ✓ resolved — DNS hostnames confirmed as `workflow-rag-mcp.kitelabs.io` and `workflow-gitnexus-mcp.kitelabs.io`.
- **D3** — ⏳ deferred — Qdrant Cloud cluster provisioning + Vault path for `QDRANT_URL` / `QDRANT_API_KEY`. Placeholder used in artifacts: Vault path `/kv/data/kitelabs/mcp`, URL `https://<PLACEHOLDER>.qdrant.cloud:6333`. Must be resolved before T7 artifacts ship.
- **D4** — ⏳ deferred — gitnexus-indexer credential policy (single dedicated SSH key + `GITHUB_TOKEN` with aggregated read access vs. per-workspace credential isolation). Placeholder used in artifacts: Vault path `/kv/data/kitelabs/mcp-gitnexus-indexer` referencing a single `SSH_PRIVATE_KEY` + `GITHUB_TOKEN`. Must be resolved before T4 (indexer code) and T7 (Secret manifest template) finalise. RAG indexer keeps per-workspace credentials regardless — D4 only scopes the GitNexus side.

### Configuration dependencies
- Every workspace runtime opting into shared mode needs in its `.env`: `MCP_PROFILE=shared`, `MCP_RAG_URL=https://workflow-rag-mcp.kitelabs.io`, `GITNEXUS_MCP_URL=https://workflow-gitnexus-mcp.kitelabs.io`, `QDRANT_URL=https://xxx.qdrant.cloud:6333`, `QDRANT_API_KEY=<key>`.
- Cluster-side K8s Secret (operator-applied from manifest template): `mcp-qdrant` (`rag-service` namespace) carrying `QDRANT_URL` + `QDRANT_API_KEY` via ExternalSecret / Vault injector.
- Cluster-side K8s Secret: `gitnexus-indexer-creds` (`git-nexus` namespace) carrying the dedicated SSH key + `GITHUB_TOKEN`.
- Cluster-side ConfigMap (operator-edited): `mcp-workspaces` in `git-nexus` namespace, mounted at `/etc/mcp/workspaces.yaml`, one entry per workspace.

### Release dependencies
- `MCP_PROFILE=local` (default) leaves every workspace's behaviour unchanged.
- `X-Workspace-Id` has a documented default on both servers — older runtime versions targeting the new endpoints continue to work.

## 6. Parallelization / blocking analysis

```
D1: ✓ X-Workspace-Id header routing accepted (default fallback when absent)
D2: ✓ DNS hostnames confirmed (workflow-rag-mcp.kitelabs.io, workflow-gitnexus-mcp.kitelabs.io)
D3: ⏳ deferred — placeholder Vault path /kv/data/kitelabs/mcp; URL https://<PLACEHOLDER>.qdrant.cloud:6333
       └── Soft-blocks ONLY the final values in T7 artifacts; does NOT block any task from starting.
D4: ⏳ deferred — placeholder: single shared SSH key + GITHUB_TOKEN at /kv/data/kitelabs/mcp-gitnexus-indexer
       └── Soft-blocks ONLY the final Secret template + tutorial wording in T7; does NOT block T4 indexer code.

T1: rag-service — rag-server X-Workspace-Id routing (picks Qdrant collection by header; default fallback)
  │  Repo: rag-service
  └── Can begin now (D1 resolved)
  │
T2: rag-service — QDRANT_API_KEY support (pass api_key to QdrantClient(...) in services/indexer/main.py:221 and services/rag_server/server.py:198)
  │  Repo: rag-service
  └── Can begin now — no blockers (additive env-var support; placeholder API key fine for tests)
  └── T1 and T2 run in parallel (same repo, different code paths)
  │
T3: git-nexus — gitnexus-server X-Workspace-Id routing with default fallback
  │  Repo: git-nexus
  └── Can begin now (D1 resolved)
  │
T4: git-nexus — multi-workspace indexer (reads /etc/mcp/workspaces.yaml ConfigMap, iterates registered workspaces; reads SSH_PRIVATE_KEY + GITHUB_TOKEN from env regardless of credential aggregation policy)
  │  Repo: git-nexus
  └── Can begin now — D4 only affects deployment Secret shape, not indexer code (env-var contract is stable)
  └── T3 and T4 run in parallel (same repo, different services)
  │
T5: rag-service — CI pipeline pushing main-<sha> images to asia.gcr.io/production-476602/rag-service
  │  Repo: rag-service
  └── BLOCKED on T1 + T2 (image must contain both)
  │
T6: git-nexus — CI pipeline pushing main-<sha> images to asia.gcr.io/production-476602/git-nexus
  │  Repo: git-nexus
  └── BLOCKED on T3 + T4 (image must contain both)
  └── T5 and T6 run in parallel
  │
T7: management-repo — produce deployment artifacts (rag-service/server Helm chart, git-nexus/server+indexer Helm charts, ArgoCD apps + AppProjects + configmaps, Vault-backed Secret templates) under docs/features/.../deployment-artifacts/ + deployment-tutorial.md
  │  Repo: management-repo
  └── Can begin now — uses placeholders for D3/D4 unresolved values:
  │      • Qdrant: QDRANT_URL=https://<PLACEHOLDER>.qdrant.cloud:6333, Vault /kv/data/kitelabs/mcp
  │      • GitNexus creds: single shared SSH + GITHUB_TOKEN at /kv/data/kitelabs/mcp-gitnexus-indexer
  └── D3/D4 must be resolved BEFORE the artifact files are pasted into kitelabs-application-infra (operator-side action, post-T7 merge). Placeholders are intentionally find/replace-able.
  └── Runs in parallel with T1–T6 (artifacts reference image tags by floating main-<sha> regex, not pinned)
  │
T8: workflow — MCP_PROFILE flag in compose templates (gate rag-server, gitnexus-server, gitnexus-indexer; keep RAG indexer running locally with QDRANT_URL/QDRANT_API_KEY pointing at Qdrant Cloud) + agent MCP client forwards X-Workspace-Id header
  │  Repo: workflow
  └── BLOCKED on T1 + T3 (servers must accept the header before runtime sends it — backward-compat default makes the dep soft; logical order T1/T3 → T8)
  │
T9: management-repo — .env.template additions (MCP_PROFILE, MCP_RAG_URL, GITNEXUS_MCP_URL, QDRANT_URL, QDRANT_API_KEY) + workspace operator notes in CLAUDE.md if needed
  │  Repo: management-repo
  └── BLOCKED on T8 (final env-var names locked)
  │
T10: workflow — operator docs (docs/rag-stack.md update + new docs/mcp-shared-infra.md describing shared-cluster mode + Qdrant Cloud)
   │  Repo: workflow
   └── BLOCKED on T7 (artifacts + tutorial finalised — docs can reference them)
   └── BLOCKED on T8 (runtime behaviour finalised)
```

**Waves**
- **Wave 0** (decisions): D1 ✓, D2 ✓, D3/D4 deferred behind placeholders — no task is blocked by an unresolved decision.
- **Wave 1** (app changes + artifact production, **all parallel, all unblocked**): T1, T2, T3, T4, T7.
- **Wave 2** (CI pipelines, parallel): T5 (after T1+T2), T6 (after T3+T4).
- **Wave 3** (runtime wiring): T8 (after T1+T3).
- **Wave 4** (docs + env, parallel): T9 (after T8), T10 (after T7+T8).
- **Operator gate** (post-Wave 1 T7 merge, before paste into `kitelabs-application-infra`): resolve D3 (provision Qdrant Cloud + Vault values) and D4 (final credential policy); patch placeholders in the artifacts before opening the GitOps PR.

## 7. Repository impact

| Repo | `workspace.yaml` id | Task-driven changes |
|---|---|---|
| `workflow` (agent-workflow) | `workflow` | `MCP_PROFILE` flag in compose templates; gate `rag-server`, `gitnexus-server`, `gitnexus-indexer`, and local `qdrant` behind a compose `profiles:` clause (RAG indexer continues to run locally); agent MCP client forwards `X-Workspace-Id`; operator docs update |
| `rag-service` | `rag-service` | rag-server `X-Workspace-Id` header routing; `QDRANT_API_KEY` env support in `QdrantClient(...)` constructors; CI image build & push to GCR |
| `git-nexus` | `git-nexus` | gitnexus-server `X-Workspace-Id` header routing; multi-workspace indexer reading ConfigMap manifest; CI image build & push to GCR |
| `management-repo` | `management-repo` | Deployment artifacts (Helm charts for rag-service/server and git-nexus/{server,indexer}; ArgoCD apps + AppProjects + configmaps; Vault-backed Secret + ConfigMap templates) under `docs/features/shared-mcp-infra-deployment/deployment-artifacts/`; `deployment-tutorial.md`; `.env.template` additions |

Out of the task system (operator handles manually via the tutorial):
- `kitelabs-application` — paste in new Helm charts: `application/rag-service/server/`, `application/git-nexus/{server,indexer}/` (PR opened by operator).
- `kitelabs-application-infra` — paste in new ArgoCD apps + AppProjects + configmaps + Vault-backed secret manifests for both stacks (PR opened by operator).
- `infrastructures` — **not touched** (Qdrant is Qdrant Cloud, not in-cluster).

## 8. Validation and release impact

### Testing expectations
- **`rag-service` unit/integration** — rag-server `X-Workspace-Id` routing tested (header present → correct collection; absent → default). `QDRANT_API_KEY` plumbing tested against a Qdrant Cloud test instance (or `qdrant` test container with API key enabled).
- **`git-nexus` unit/integration** — multi-workspace indexer tested with a 2-workspace manifest fixture; gitnexus-server `X-Workspace-Id` routing tested for present/absent/unknown.
- **Cluster smoke test** (post-deployment) — bring up a workspace runtime with `MCP_PROFILE=shared`, run an MCP query, confirm responses are scoped to the right workspace.
- **Isolation test** — two workspaces with distinct content; query workspace A, confirm zero leakage from workspace B (RAG: collection isolation in Qdrant Cloud; GitNexus: subtree isolation by `X-Workspace-Id`).
- **GitNexus podAffinity smoke test** — confirm gitnexus-server and gitnexus-indexer schedule on the same node and share the `gitnexus-data` PVC.

### Migration / config impact
- No data migration. Each workspace's first cycle under `MCP_PROFILE=shared` cold-starts indexing into the cluster Qdrant; gitnexus-indexer picks up the workspace from the ConfigMap on its next cycle.
- Default `MCP_PROFILE=local` leaves existing workspaces untouched.

### Rollout
1. Land T1–T6 (app + CI changes). Confirm `main-<sha>` images appear in GCR.
2. Land T7 (artifacts + tutorial) in management-repo.
3. Operator applies the tutorial: paste artifacts into `infrastructures` → `kitelabs-application` → `kitelabs-application-infra`. Land the ArgoCD apps; the cluster syncs Qdrant → rag-service → git-nexus.
4. Land T8 (runtime header wiring) and T9 (env template).
5. Convert one pilot workspace via `MCP_PROFILE=shared`. Monitor for one day.
6. Roll out remaining workspaces.

### Backward compatibility
- `MCP_PROFILE=local` (default) preserves existing behaviour.
- `X-Workspace-Id` has a documented default on both servers — older runtime versions targeting the new endpoints work without immediate update.
- No auth in v1 means no header to break. Adding auth later is additive (new `Authorization` header; absent = legacy behaviour, present = enforced).

### Deployment / handoff
- A `deployment-checklist.md` will be authored at the handoff stage (workflow rule forbids premature creation).
- The handoff PR includes `docs/mcp-shared-infra.md` (in `agent-workflow`) and links from `docs/rag-stack.md`. The tutorial (T7) is the operator-facing version of the same content, scoped to the artifact paste flow.
