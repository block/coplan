# CoPlan — Agent Guidelines

## What This Is

A Rails app for engineering design doc review, purpose-built for AI-assisted planning. Plans get better through collaboration — domain experts leave inline feedback, AI agents respond to that feedback and apply edits automatically, and every change is versioned with full provenance. Humans comment, AI agents edit. Local agents interact via the REST API using skills (see `coplan` skill) and future CLIs.

## Architecture: Engine vs Host App

Most of the application logic lives in the **CoPlan Rails engine** (`engine/`), packaged as the `coplan` gem (path-based, in `Gemfile`). The top-level Rails app is a **thin host** that provides deployment configuration, ActiveAdmin, and app-specific glue.

### Engine (`engine/`) — where the code lives
- **Models** — all domain models live in `engine/app/models/coplan/` (Plan, PlanVersion, User, Comment, CommentThread, EditLease, EditSession, ApiToken, AutomatedPlanReviewer, PlanCollaborator)
- **Controllers** — web UI and API controllers in `engine/app/controllers/coplan/`, including `api/v1/` for the REST API
- **Services** — all service objects in `engine/app/services/coplan/` (Plans::Create, Plans::ApplyOperations, AI providers, etc.)
- **Policies** — authorization policies in `engine/app/policies/coplan/`
- **Jobs** — background jobs in `engine/app/jobs/coplan/`
- **Views, helpers, assets, JS** — all Hotwire views and Stimulus controllers
- **Migrations** — engine-owned tables go in `engine/db/migrate/`
- **Routes** — engine routes in `engine/config/routes.rb`, mounted by the host

### Host app (top-level) — thin deployment shell
- **ActiveAdmin** — admin registrations in `app/admin/`
- **Auth** — `SessionsController`, `User` model (legacy, being migrated to `CoPlan::User`)
- **App-specific integrations** — `SlackClient`, `SlackNotificationJob`
- **Migrations** — only for data migrations, FK rewiring, or host-specific tables in `db/migrate/` (the engine owns schema for `coplan_*` tables)
- **Config** — database, deployment, environment, seeds

**When adding new features, put them in the engine** unless they are deployment- or host-specific (admin UI, external integrations, auth).

## Tech Stack & Philosophy

- **Rails** with importmaps — no Node, no bundler, no Webpack, no esbuild
- **Hotwire** — Turbo Drive, Turbo Frames, Turbo Streams, Stimulus
- **Plain CSS** — no Tailwind, no preprocessors
- **Plain JavaScript** — via importmaps and Stimulus controllers only
- **MySQL 8** — but schema must stay portable (no PG-only or MySQL-only features); **no `default:` on JSON columns** (use `after_initialize` in the model instead)
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
- **Prefer server-rendered HTML with standard Stimulus bindings** (`data-controller`, `data-action`, `data-*-target`) — direct `addEventListener` is a last resort, only when elements are created dynamically in JS and Stimulus can't bind to them (e.g., inline text highlights wrapping arbitrary DOM ranges). Even these cases should be revisited for server-side alternatives when practical.

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

## Comment & Review UX

The comment system is central to the collaboration workflow. Domain experts leave inline feedback anchored to specific text in the plan, and the plan author triages that feedback.

### Thread lifecycle
- **Reviewer comments** start as `pending` (awaiting author triage)
- **Author's own comments** start as `todo` (self-assigned work items)
- Author triages pending feedback: **Accept** (`pending → todo`) or **Discard** (`pending → discarded`)
- Author marks completed work: **Resolve** (`todo → resolved`)
- Resolved/discarded threads can be **Reopened** back to `pending`

### Inline review UI
- **Highlights**: anchored text is wrapped in `<mark>` elements — amber for `pending`, blue for `todo`, unstyled for `resolved`
- **Margin dots**: colored indicators in the left margin aligned to each highlight's vertical position
- **Thread popovers**: native HTML Popover API (`popover="auto"`) showing the comment thread, reply form, and action buttons; positioned relative to the anchor and tracked on scroll
- **Comment toolbar**: fixed bottom bar showing open thread count, j/k navigation, and a "Show resolved" toggle

### Keyboard shortcuts
- `j` / `k` — navigate between open threads (scrolls to highlight, opens popover)
- `r` — focus the reply textarea in the current popover
- `a` — accept the current pending thread
- `d` — discard the current pending thread
- `Enter` — submit reply; `Shift+Enter` — newline

### How thread data flows
- Thread data is **server-rendered** as hidden `[data-anchor-text]` elements in `#plan-threads` (via `_thread_popover.html.erb`)
- The `text_selection_controller` reads that data and creates highlight marks + margin dots client-side (text range wrapping requires browser DOM APIs)
- Status changes broadcast via Turbo Streams → `Broadcaster.replace_to` replaces the thread data in-place → `MutationObserver` on `#plan-threads` re-runs `highlightAnchors()` to update the visual state
