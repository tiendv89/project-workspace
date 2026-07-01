# Product Specification

## Feature
- Feature ID: `m4-admin-control-model-config`
- Title: Admin-Configurable Model Catalog & Pricing

## Background

[[m4-agent-cost]] introduced `model_pricing` in `user-service` — a table of per-model USD
rates seeded with "current Anthropic pricing" at migration time — plus the admin panel
(`/admin/` tree, `platform_admin`-gated) in `digital-factory-ui`. That feature covers cost
*capture and metering*; it does not give an admin any way to *manage* the model catalog
itself day-to-day. Model identity (name, id) is also hardcoded on the frontend, separate
from whatever `user-service` knows about pricing.

This feature closes that gap: it gives an admin a UI, inside the existing admin panel, to
add, edit, and retire model catalog entries — so that a new model release or a provider
pricing change is a data update, not a code deploy.

## Problem

### Model pricing is not admin-editable day-to-day

`model_pricing` exists in `user-service`, but nothing in the product lets an admin open it
up and change a rate. When Anthropic adjusts per-token pricing for an existing model, an
engineer has to touch a migration or seed script and redeploy `user-service` to reflect the
new rate. There is no self-service path for the person who actually owns pricing decisions.

### New model releases require a code change, not a config change

When a new model ships — e.g. Claude Sonnet 5 — supporting it today means: add a row to
`model_pricing` (migration), *and* separately update whatever is hardcoded on the frontend
so the model shows up as selectable and displays the right name. Two repos, two deploys,
for what should be a single admin action.

### Model name/id is hardcoded on the frontend

`digital-factory-ui` hardcodes the list of model names/ids shown to users (e.g. in model
pickers, agent config, cost displays). This list has no single source of truth — it drifts
from whatever `user-service` actually has priced, and every addition or rename requires a
frontend code change and release.

### No visibility into what's currently priced or active

There's no page anywhere that shows "these are all the models we currently support and
what they cost" — an admin has to query the database directly to answer that question.

## Goals

- **G1 — Model catalog admin page.** An admin can view a list of all model catalog entries
  (model id, display name, pricing rates, active/retired status) inside the existing
  `/admin/` tree in `digital-factory-ui`, gated the same way as other admin pages
  (`platform_admin` role, per [[m4-agent-cost]]).
- **G2 — Add a new model without a deploy.** An admin can add a new model entry (model id,
  display name, input/output/cache pricing) through the admin UI. The model becomes
  available to the rest of the product (selectable, priced, displayed) immediately —
  no frontend or backend redeploy required.
- **G3 — Edit an existing model's name or pricing.** An admin can update a model's display
  name and/or its pricing rates. A pricing change takes a new `effective_from` timestamp so
  historical cost records (`turn_cost`) computed under the old rate are not altered
  retroactively — only new usage is priced at the new rate.
- **G4 — Retire a model.** An admin can mark a model as retired/inactive so it no longer
  appears as selectable for new sessions, while its pricing history remains intact for
  existing cost records and reporting.
- **G5 — Single source of truth for model identity.** The frontend (and any other service
  that needs to display or select a model) reads the model catalog from this data source
  instead of a hardcoded list. Adding, renaming, or retiring a model in the admin UI is
  reflected everywhere the model is shown, with no separate frontend change.
- **G6 — Designate a default model.** An admin can mark one active model as the default
  used for new sessions/agents when no explicit model is chosen.

## Non-goals

- **NG1 — No automatic sync from the provider.** The catalog is admin-maintained data;
  this feature does not build a job that discovers or imports new models from Anthropic
  automatically.
- **NG2 — No end-user-facing model management.** Only `platform_admin`-gated users can add,
  edit, or retire catalog entries — regular users only see the resulting model list.
- **NG3 — No change to model routing/invocation logic.** This feature governs the catalog
  and pricing *data*; it does not change how a model is actually selected or called at
  runtime (model gateway / routing is a separate concern per the roadmap's enabling tracks).
- **NG4 — No retroactive re-pricing.** Editing a model's rate never rewrites previously
  recorded `turn_cost` rows — historical cost stays computed at the rate that was effective
  when the turn happened.
- **NG5 — No multi-provider catalog in this pass.** Scoped to the models `user-service`
  already prices (Anthropic/Claude family); a general multi-provider catalog is out of
  scope unless called out in technical design.
