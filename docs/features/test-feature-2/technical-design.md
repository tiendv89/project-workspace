# Technical Design

## Feature
- Feature ID: `test-feature-2`
- Title: AI-Powered Plant Whisperer

## Current State

There is no existing plant care application or codebase. This is a greenfield product. The workspace currently has a single repository (`management-repo`) that serves as the planning and documentation hub.

No AI inference infrastructure, plant taxonomy database, mobile SDK, notification pipeline, or user account system exists today. All components must be designed and built from scratch.

## Constraints

- The workspace has a single registered repo (`management-repo`). All implementation tasks will reference this repo until additional implementation repos are registered in `workspace.yaml`.
- The product is scoped to **indoor houseplants only** — no outdoor/garden species for v1.
- Network connectivity is **required** — no offline AI inference.
- The initial plant library must cover at least **500 species**.
- AI inference must return a diagnosis within an acceptable user-facing latency (target: < 3 seconds on a mid-range mobile device with a stable connection).
- Push notifications must be actionable and non-spammy — users should not disable them.

## Options Considered

### Option A — Monolithic Mobile App with On-Device ML Model
Build a React Native (or Flutter) app that bundles a lightweight MobileNet-style TensorFlow Lite model for plant diagnosis directly on the device.

- **Pros:**
  - Works offline (no latency from network round-trip for inference)
  - No backend inference cost per request
  - Simpler architecture — fewer moving parts
- **Cons:**
  - On-device model accuracy is significantly lower than server-side vision models (GPT-4o, Google Gemini Vision, AWS Rekognition)
  - Larger app binary size (~50–150 MB for a viable model)
  - Model updates require app store releases
  - Personalised scheduling and climate data integration still requires a backend
  - Push notification scheduling still requires a backend
- **Implementation impact:** Medium mobile, low backend
- **Dependency impact:** TensorFlow Lite, Expo/React Native, app store approval

### Option B — Mobile App + Cloud AI Backend (Chosen)
Build a mobile frontend (React Native / Expo) that sends plant photos to a cloud backend (Node.js / FastAPI). The backend calls a best-in-class vision AI (OpenAI GPT-4o Vision or Google Gemini 1.5 Pro Vision), returns a structured diagnosis, and handles scheduling, notification dispatch, and the plant library.

- **Pros:**
  - Best possible diagnosis accuracy using frontier vision models
  - Model upgrades happen server-side — no app store releases required
  - Central place to store plant library, user data, schedules, and notification state
  - Enables personalisation using historical care data over time
  - Simpler mobile client (no large ML binary)
- **Cons:**
  - Requires network connectivity at diagnosis time
  - Inference cost per request (mitigated by caching repeated species queries)
  - Backend must be maintained and scaled
- **Implementation impact:** Medium backend, medium mobile, light infrastructure
- **Dependency impact:** OpenAI / Google AI API key, push notification provider (Expo Push / FCM / APNs), cloud hosting

### Option C — Pure Web App (No Mobile)
Build a Progressive Web App instead of a native mobile experience.

- **Pros:**
  - No app store approval required
  - Single codebase for all platforms
- **Cons:**
  - Camera API on mobile browsers is less reliable than native camera access
  - Push notifications on iOS PWAs are limited (only available since iOS 16.4)
  - Poor UX for a camera-centric workflow
- **Implementation impact:** Lower — just a web frontend
- **Dependency impact:** Less — no native SDKs
- **Verdict:** Rejected. The core UX (point camera at plant, get result) is fundamentally mobile-native.

## Chosen Design

**Option B — Mobile App + Cloud AI Backend** is selected.

### Architecture Overview

```
[Mobile App — React Native / Expo]
        │  (HTTPS, multipart image upload)
        ▼
[REST API — Node.js / Express or FastAPI]
        │
        ├──► [Vision AI — GPT-4o Vision / Gemini 1.5 Pro Vision]
        │         └── Structured JSON diagnosis response
        │
        ├──► [Plant Library — PostgreSQL + species care profiles]
        │
        ├──► [User Schedules — PostgreSQL, per-plant watering/fertilisation]
        │
        └──► [Notification Scheduler — cron / job queue → Expo Push / FCM / APNs]
```

### Key design decisions

1. **Vision AI provider**: Start with OpenAI GPT-4o Vision (best accuracy, structured JSON output via function calling). Abstract the provider behind an `AIAdapter` interface so it can be swapped to Gemini or a fine-tuned model later without changing application logic.

2. **Plant library**: Seed a PostgreSQL table with 500+ species from an open dataset (e.g. the USDA PLANTS database or Trefle API). Each row stores: `species_id`, `common_name`, `scientific_name`, `watering_frequency_days`, `light_requirement`, `fertilisation_schedule`, `care_notes`.

3. **Diagnosis flow**: Mobile sends `{image_base64, user_id, plant_id?}` → backend calls vision AI with a structured prompt → AI returns `{health_status, issues[], confidence, recommended_actions[]}` → backend stores result and returns to client.

4. **Personalised schedules**: After first diagnosis, backend creates a `PlantSchedule` record per user-plant pair with computed `next_water_at` and `next_fertilise_at` timestamps, adjusted for local climate data fetched from a weather API (Open-Meteo — free, no API key required for basic use).

5. **Push notifications**: A cron job runs every hour. It queries schedules where `next_water_at <= now() + 2h`. For each match it fires an Expo Push notification. Users can snooze or mark as done from the notification.

6. **Gamification**: A `plant_health_score` (0–100) is computed per plant on each diagnosis. Streaks track consecutive days with a score ≥ 70. Achievements are seeded as a static table and unlocked by server-side rules evaluated after each diagnosis.

### Affected repositories

- `management-repo` — feature docs and task state (this repo, planning only)

> **Note:** For a production build, two additional repos would be registered: a `mobile-app` repo (React Native) and a `backend-api` repo (Node.js or Python). Since the workspace currently declares only `management-repo`, all tasks below target that repo for planning/scaffolding purposes. Registering additional repos is a prerequisite for full implementation.

## Dependency Analysis

| Dependency | Type | Status | Blocker? |
|---|---|---|---|
| OpenAI API key (GPT-4o Vision) | External vendor | Unresolved — must be provisioned | Yes — blocks diagnosis tasks |
| Expo account + push notification credentials | External vendor | Unresolved | Yes — blocks notification tasks |
| PostgreSQL instance (cloud or local dev) | Infrastructure | Unresolved | Yes — blocks backend data tasks |
| Open-Meteo weather API | External API | Available (free, no key) | No |
| Plant species seed dataset | Data | Unresolved — source must be chosen | Yes — blocks plant library task |
| App store accounts (Apple + Google) | External | Unresolved | Yes — blocks production release (not v1 tasks) |
| Additional impl repos in `workspace.yaml` | Workspace config | Absent — only `management-repo` exists | Yes — blocks any non-management task |

**Blocking decisions that must be resolved before implementation begins:**

- **D1**: Confirm AI provider — OpenAI GPT-4o Vision or Google Gemini 1.5 Pro Vision (or both with A/B)?
- **D2**: Choose backend language/framework — Node.js/Express or Python/FastAPI?
- **D3**: Identify and license a plant species dataset for the initial 500-species library.
- **D4**: Register `mobile-app` and `backend-api` repos in `workspace.yaml`.

## Parallelization / Blocking Analysis

```
D1: Confirm AI vision provider (OpenAI vs Gemini) ──┐
D2: Choose backend framework (Node vs FastAPI)      ──┤  resolve before T3/T4
D3: Source plant species dataset                    ──┤  resolve before T2
D4: Register impl repos in workspace.yaml           ──┘  resolve before any impl task

T1: Scaffold backend API project structure + CI
  └── Can begin now — no blockers (uses management-repo for scaffolding docs)

T2: Seed plant library (500+ species) into PostgreSQL
  └── BLOCKED on D3 (dataset source must be chosen and licensed)
  └── BLOCKED on T1 (backend project must exist)

T3: Implement vision AI diagnosis endpoint
  └── BLOCKED on D1 (AI provider must be confirmed)
  └── BLOCKED on D2 (backend framework must be chosen)
  └── BLOCKED on T1 (backend scaffold must exist)

T4: Implement personalised watering/fertilisation scheduler
  └── BLOCKED on T2 (plant library schema must be finalised)
  └── BLOCKED on T3 (diagnosis result schema must be stable)

T5: Implement push notification cron + Expo Push integration
  └── BLOCKED on T4 (schedule records must exist to query)

T6: Mobile app — camera capture + diagnosis UI
  └── BLOCKED on T3 (diagnosis API must be available)
  └── Can begin stub/skeleton now (T3 unblocks wiring)

T7: Mobile app — plant dashboard + health score + gamification UI
  └── BLOCKED on T6 (core plant UI must exist)
  └── BLOCKED on T4 (schedule data must be available)

T8: Mobile app — push notification deep-link handling
  └── BLOCKED on T5 (notifications must be firing)
  └── BLOCKED on T6 (plant detail screen must exist)

T2 and T3 run in parallel once T1 and their respective D-decisions are resolved.
T6, T7, T8 form a sequential mobile chain after the backend tasks stabilise.
```

## Repository Impact

| Repo | Impact |
|---|---|
| `management-repo` | Feature docs, task YAML state, this technical design — planning artifacts only |

> When `mobile-app` and `backend-api` repos are registered, T1–T5 will target `backend-api` and T6–T8 will target `mobile-app`.

## Validation and Release Impact

- **Testing**: Backend endpoints should have unit tests (Jest or pytest) for the diagnosis adapter, scheduler logic, and notification trigger. Mobile app should have component tests for the camera flow and dashboard.
- **Migration**: Initial DB migration seeds the plant library. Schema changes after that must be versioned with a migration tool (e.g. Flyway, Alembic, or `node-pg-migrate`).
- **Rollout**: v1 is a closed beta — invite-only via TestFlight (iOS) and Google Play Internal Testing. No public launch until push notification volume and AI cost per diagnosis are validated at small scale.
- **Backward compatibility**: No existing users — no backward compat constraints for v1.
- **Cost guardrail**: Each GPT-4o Vision call costs approximately $0.01–$0.03 per image. A rate limit per user (e.g. 10 diagnoses/day free tier) should be enforced server-side from day one to prevent runaway API costs.
- **Privacy**: Plant photos are sent to the AI provider. The privacy policy must disclose this. Images should not be stored permanently on the backend unless the user opts in.
