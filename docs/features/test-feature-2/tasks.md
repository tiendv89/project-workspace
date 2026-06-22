# Tasks — AI-Powered Plant Whisperer (`test-feature-2`)

> Feature status: `in_tdd` | Stage: `tasks` | Machine state lives in `tasks/T<n>.yaml`

## Dependency Diagram

```
D1: Confirm AI vision provider (OpenAI vs Gemini) ──┐
D2: Choose backend framework (Node vs FastAPI)      ──┤  resolve before T3/T4
D3: Source plant species dataset                    ──┤  resolve before T2
D4: Register impl repos in workspace.yaml           ──┘  resolve before any impl task

T1: Scaffold backend API project structure + CI
  └── Can begin now — no blockers

T2: Seed plant library (500+ species) into PostgreSQL
  └── BLOCKED on T1 (backend scaffold must exist)
  └── BLOCKED on D3 (dataset source must be licensed and chosen)

T3: Implement vision AI diagnosis endpoint
  └── BLOCKED on T1 (backend scaffold must exist)
  └── BLOCKED on D1 (AI provider must be confirmed)
  └── BLOCKED on D2 (backend framework must be chosen)

T2 and T3 run in parallel once T1 and their D-decisions are resolved.

T4: Implement personalised watering/fertilisation scheduler
  └── BLOCKED on T2 (plant library schema must be finalised)
  └── BLOCKED on T3 (diagnosis result schema must be stable)

T5: Implement push notification cron + Expo Push integration
  └── BLOCKED on T4 (schedule records must exist to query)

T6: Mobile app — camera capture + diagnosis UI
  └── BLOCKED on T3 (diagnosis API must be available for wiring)

T7: Mobile app — plant dashboard + health score + gamification UI
  └── BLOCKED on T6 (core plant UI must exist)
  └── BLOCKED on T4 (schedule data must be available)

T8: Mobile app — push notification deep-link handling
  └── BLOCKED on T5 (notifications must be firing)
  └── BLOCKED on T6 (plant detail screen must exist)
```

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Scaffold backend API project structure + CI | — |
| T2 | 2 | Seed plant library (500+ species) into PostgreSQL | T1 |
| T3 | 2 | Implement vision AI diagnosis endpoint | T1 |
| T4 | 3 | Implement personalised watering/fertilisation scheduler | T2, T3 |
| T5 | 4 | Implement push notification cron + Expo Push integration | T4 |
| T6 | 2 | Mobile app — camera capture + diagnosis UI | T3 |
| T7 | 3 | Mobile app — plant dashboard + health score + gamification UI | T6, T4 |
| T8 | 4 | Mobile app — push notification deep-link handling | T5, T6 |

---

## T1 — Scaffold backend API project structure + CI

### Description
Bootstrap the backend API repository with the chosen framework (Node.js/Express or Python/FastAPI). Set up project scaffolding, linting, formatting, a health-check endpoint, Docker Compose for local development (app + PostgreSQL), and a CI pipeline (GitHub Actions) that runs lint and tests on every push. This is the foundation all other backend tasks depend on.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Initialise project (package.json / pyproject.toml)
- [ ] Configure linter + formatter (ESLint/Prettier or ruff)
- [ ] Add `GET /health` endpoint
- [ ] Add `docker-compose.yml` with app + postgres services
- [ ] Add GitHub Actions CI workflow (lint + test on push)
- [ ] Write a README with local dev setup instructions

---

## T2 — Seed plant library (500+ species) into PostgreSQL

### Description
Design the `species` table schema and populate it with at least 500 indoor houseplant species. Source data from an open dataset (e.g. Trefle API, USDA PLANTS, or an open Kaggle dataset). Each row must capture: `species_id`, `common_name`, `scientific_name`, `watering_frequency_days`, `light_requirement`, `fertilisation_schedule`, `care_notes`. Write a seed script and a DB migration file.

### Required skills
- postgres-best-practices

### Subtasks
- [ ] Choose and license a plant species dataset (resolves D3)
- [ ] Write DB migration: create `species` table
- [ ] Write seed script that imports dataset into PostgreSQL
- [ ] Validate: confirm ≥ 500 rows, no nulls on required fields
- [ ] Add `GET /species` and `GET /species/:id` read endpoints

---

## T3 — Implement vision AI diagnosis endpoint

### Description
Implement `POST /diagnose` — accepts a plant image (multipart or base64), calls the chosen vision AI provider (GPT-4o Vision or Gemini 1.5 Pro Vision) via an `AIAdapter` interface, and returns a structured diagnosis: `{health_status, issues[], confidence, recommended_actions[]}`. The adapter pattern allows swapping providers without touching application logic. Include response caching for identical species+symptom combinations to reduce API cost.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Define `AIAdapter` interface (TypeScript) or abstract class (Python)
- [ ] Implement `OpenAIAdapter` using GPT-4o Vision (function calling for structured JSON)
- [ ] Implement `GeminiAdapter` stub (for future swap)
- [ ] Add `POST /diagnose` route wired to the adapter
- [ ] Add rate limiting: max 10 diagnoses/user/day
- [ ] Add response caching (Redis or in-memory LRU) for repeated queries
- [ ] Write unit tests for the adapter and route

---

## T4 — Implement personalised watering/fertilisation scheduler

### Description
After a successful diagnosis, create or update a `PlantSchedule` record per user-plant pair. Compute `next_water_at` and `next_fertilise_at` using the species base frequency adjusted by local climate data from the Open-Meteo API (humidity, temperature). Expose `GET /schedules/:userId` so the mobile app can display upcoming care tasks.

### Required skills
- postgres-best-practices

### Subtasks
- [ ] Write DB migration: create `plant_schedules` table
- [ ] Integrate Open-Meteo API to fetch local humidity/temperature by lat/lng
- [ ] Write schedule computation logic (base frequency × climate adjustment factor)
- [ ] Hook schedule creation/update into the `POST /diagnose` response flow
- [ ] Add `GET /schedules/:userId` endpoint
- [ ] Write unit tests for the scheduling algorithm

---

## T5 — Implement push notification cron + Expo Push integration

### Description
Build a cron job (runs every hour) that queries `plant_schedules` for records where `next_water_at <= now() + 2h`. For each match, fire an Expo Push notification to the user's registered device token. Users can snooze or mark-as-done from the notification (handled via a `PATCH /schedules/:id/snooze` and `PATCH /schedules/:id/done` endpoint). Store `device_token` per user in a `user_devices` table.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Write DB migration: create `user_devices` table
- [ ] Add `POST /devices` endpoint to register Expo push tokens
- [ ] Integrate Expo Push SDK (`expo-server-sdk`)
- [ ] Implement cron job (node-cron or equivalent) that fires notifications
- [ ] Add `PATCH /schedules/:id/snooze` (pushes `next_water_at` by 4h)
- [ ] Add `PATCH /schedules/:id/done` (marks watering complete, computes next cycle)
- [ ] Write integration test for the notification trigger logic

---

## T6 — Mobile app — camera capture + diagnosis UI

### Description
Build the core mobile flow: user opens the app, taps "Diagnose My Plant", the device camera opens, user captures or uploads a photo, and the app calls `POST /diagnose`. Display a loading state during inference, then render the diagnosis result card (health status badge, issue list, recommended actions). This is the primary value-delivery screen.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Bootstrap React Native / Expo project
- [ ] Implement camera capture screen using `expo-camera`
- [ ] Implement image upload to `POST /diagnose` with multipart form
- [ ] Build diagnosis result card component (health status, issues, actions)
- [ ] Add loading skeleton and error state
- [ ] Add species selector (typeahead from `GET /species`) for optional pre-hint
- [ ] Write component tests for the result card

---

## T7 — Mobile app — plant dashboard + health score + gamification UI

### Description
Build the plant dashboard: a list of the user's plants with their current health score (0–100), upcoming care schedule, and streak counter. Include an achievements screen that shows locked/unlocked badges. The health score and streak are computed server-side; the mobile app reads them from `GET /schedules/:userId` and a `GET /users/:id/stats` endpoint added in this task.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Backend: add `GET /users/:id/stats` returning `{health_score, streak_days, achievements[]}`
- [ ] Backend: implement achievement unlock rules (evaluated post-diagnosis)
- [ ] Mobile: build plant list screen with health score badge and next-care countdown
- [ ] Mobile: build achievements screen (locked/unlocked badge grid)
- [ ] Mobile: build streak counter widget on home screen
- [ ] Write component tests for dashboard and achievements screens

---

## T8 — Mobile app — push notification deep-link handling

### Description
Handle incoming Expo push notifications in the mobile app. When a user taps a "Your monstera looks thirsty!" notification, deep-link to the relevant plant's detail screen. Implement the snooze and mark-as-done actions directly from the notification banner (using notification action buttons). Register the user's Expo push token on app launch via `POST /devices`.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Register Expo push token on app launch (`POST /devices`)
- [ ] Configure `expo-notifications` for foreground + background handling
- [ ] Implement deep-link routing: notification → plant detail screen
- [ ] Add notification action buttons: "Snooze 4h" (`PATCH /schedules/:id/snooze`) and "Done" (`PATCH /schedules/:id/done`)
- [ ] Test notification flow on iOS simulator and Android emulator
