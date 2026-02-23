# Planning Department — Agent Guidelines

## What This Is

A Rails app for managing engineering design doc review, purpose-built for AI-generated plans. Humans comment, AI agents edit. Local agents interact via the REST API using skills (see `planning-department` skill) and future CLIs.

## Tech Stack & Philosophy

- **Rails** with importmaps — no Node, no bundler, no Webpack, no esbuild
- **Hotwire** — Turbo Drive, Turbo Frames, Turbo Streams, Stimulus
- **Plain CSS** — no Tailwind, no preprocessors
- **Plain JavaScript** — via importmaps and Stimulus controllers only
- **MySQL 8** — but schema must stay portable (no PG-only or MySQL-only features)
- **SolidQueue** for background jobs, **SolidCable** for ActionCable
- **ActiveAdmin 4 beta** + `activeadmin_assets` for admin UI — no node/tailwind needed
- **No Devise, no OmniAuth** — auth is hand-rolled (stub OIDC in dev, real OIDC later)

## Database Conventions

- All tables use **UUID primary keys** (`id: :string, limit: 36`), assigned in `ApplicationRecord#assign_uuid`
- All multi-tenant tables include `organization_id` (FK, not null)
- Enums are stored as **strings** (not integers) — validated with constants and `inclusion:` validators
- JSON columns for arrays/hashes (`tags`, `metadata`, `trigger_statuses`, `allowed_email_domains`)
- No PG-only types (`citext`, `text[]`, `ON CONFLICT ... WHERE`) — use Rails validations and `json` columns
- `Current.organization` and `Current.user` are set per-request for scoping

## Model Conventions

- Define valid values as **frozen constants** on the model (e.g., `Plan::STATUSES`, `AutomatedPlanReviewer::AI_PROVIDERS`)
- Use `inclusion:` validations against those constants
- Use `after_initialize` for defaults on JSON array columns (e.g., `self.tags ||= []`)
- Service objects live in `app/services/` namespaced by model (e.g., `Plans::Create`)
- Service objects use the `self.call` + `new(...).call` pattern
- Authorization uses plain policy objects in `app/policies/` — not Pundit

## Frontend Conventions

- JavaScript goes in `app/javascript/controllers/` as Stimulus controllers
- No npm packages — everything through importmaps or inline
- Views use Turbo Frames for partial page updates, Turbo Streams for realtime broadcasts
- Keep it simple: no React, no Vue, no component libraries

## Testing

- **RSpec** with `rspec-rails`
- Run the full suite: `bundle exec rspec`
- Spec files mirror app structure: `spec/models/`, `spec/requests/`, `spec/services/`, `spec/helpers/`
- Use **FactoryBot** (`factory_bot_rails`) — factories live in `spec/factories/`
- Every model, service object, and controller action should have specs
- UUID primary keys are auto-assigned by `ApplicationRecord#assign_uuid` — do **not** set `id` in factories
- Factories derive associations from parent objects (e.g., `organization { plan.organization }`) to keep data consistent
- FactoryBot syntax methods (`create`, `build`) are included globally via `config.include FactoryBot::Syntax::Methods`
- `sign_in_as(user)` helper is defined in `spec/rails_helper.rb` for request specs

## Seeds

- `db/seeds.rb` must be **idempotent** — use `find_or_create_by!` or guard with count checks
- Seeds should provide enough data to demo features from a fresh checkout
- `AutomatedPlanReviewer.create_defaults_for(org)` handles reviewer seeding

## Code Review

- Run the `code-review` skill before considering a session complete
- Address all feedback until the review passes

## ActiveAdmin

- New models get an ActiveAdmin registration in `app/admin/`
- Define `ransackable_attributes` and `ransackable_associations` on models for ActiveAdmin search

## Key Domain Concepts

- **Plan statuses**: `brainstorm → considering → developing → live` (or `→ abandoned`)
- **Brainstorm** plans are private; **considering+** are published to the org
- **Editing model**: humans comment, AI agents apply edits via semantic operations (`replace_exact`, `insert_under_heading`, `delete_paragraph_containing`)
- **Edit leases**: one agent edits at a time, enforced by a lease with TTL
- **Cloud Personas** (AutomatedPlanReviewers): server-side prompt templates that run as SolidQueue jobs
- **Versions are immutable** — every edit creates a new PlanVersion with full provenance
