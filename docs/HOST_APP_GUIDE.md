# Coplan Host App Integration Guide

## Overview

Coplan is a Rails engine that manages collaborative planning documents. It owns its own `Coplan::User` model and handles authentication internally via a callback you configure.

## Upgrading to the Coplan namespace

Update the host's Ruby references to `Coplan::`, including routes, initializers,
and jobs. Use `bin/rails coplan:install:migrations` to copy the engine migrations
into the host before deploying.

Pause old web processes and job workers before running `bin/rails db:migrate`.
`RenameCoplanClassNames` updates library owners, attachments, and ActiveAdmin
comments. Start the new processes after the migration so old writers cannot
reintroduce the previous class names. Jobs queued before the cutover may need
to be re-enqueued if their serialized names use the previous namespace.

To roll back, pause writers again, run the migration down using the new code,
then start the previous application version.

## Interactive document components

In a Markdown plan, an author can use a JavaScript component region. Coplan supplies an opaque-origin frame on the existing host. If the host sets its own Content Security Policy, its `frame-src` must permit the engine’s `/_/component-frame` URL, including any mount prefix. Host policy still applies to the plan page. To show component source only, set `config.components_enabled = false` in `Coplan.configure`.

The shell blocks remote resources and fetch, disables peer connections, and sends a deny-all connection policy where supported. Browser support for complete network isolation varies. A host that requires guaranteed zero egress can use source-only rendering.

Register browser-ready ES modules at boot. The catalog, examples, and registered source appear in the public `/agent-instructions/components` guide. Bundle only code intended for delivery to readers. A type may export async `setup({root, title})` returning its declared bindings and `mount({root, ...bindings})` to render the result. Both run inside the same frame as the author script.

```ruby
Coplan.configure do |config|
  config.component_catalog.library("backoff@1",
    source: "export const delay = n => 2 ** n", example: 'const { delay } = await import("backoff")')
  config.component_catalog.type("retry", uses: [ "backoff@1" ], bindings: [ "delay" ],
    source: 'import { delay } from "backoff"; export function setup() { return { delay }; }',
    guide: "Use delay(attempt) to calculate the backoff in seconds.",
    example: 'root.textContent = delay(3)')
end
```

The visual editor lists registered types under **+ → Component**. Supply a runnable author script in `example:` to seed new blocks. Optional plain-text `guide:` explains the type in the editor’s quick guide and the agent reference.

Install the engine migration when upgrading. Each new revision that contains components saves its selected modules, their digests, and any type wrappers. Old revisions without a catalog display source. Disabling execution also disables the frame endpoint.

## Rendered-content caching

Rendered plan bodies, comments, previews, and citations use standard Rails
caching with a 15-minute expiry. Content edits change the cache key immediately.
Renderer code changes appear as entries expire; no version bump or release
configuration is required. The host's normal cache store and fragment-caching
settings apply.

## User settings and host integrations

Coplan owns the settings shown on its Settings page. The app theme, light/dark
mode and push-to-talk preferences live in `coplan_users.app_theme`,
`coplan_users.theme_preference` and `coplan_users.voice_hotkey`.
Notification preferences have their own column; browser subscriptions and API
tokens have engine-owned tables. User `metadata` is available for host directory
data and is not a settings API.

When upgrading from metadata-backed settings, install and run the engine migration:

```sh
bin/rails coplan:install:migrations
bin/rails db:migrate
```

`MoveUserSettingsOutOfMetadata` copies valid existing mode and hotkey values,
including explicit System and Off choices. Missing or invalid values use System
and Ctrl+Space. Preferences erased by an earlier directory sync cannot be recovered.
Rollback copies the latest settings back into metadata while preserving host fields.

Pause directory sync and preference writes during this migration and restart all
app processes on the new version before resuming them: old processes still write
settings to metadata, which the new version no longer reads.

## Setup

### 1. Add the gem

```ruby
# Gemfile
gem "coplan-engine", require: "coplan"
```

Then run `bundle install`.

### 2. Mount the engine

```ruby
# config/routes.rb
mount Coplan::Engine, at: "/coplan"
```

You can also mount at the root if Coplan is the primary purpose of your app. When doing so, add `as: "coplan"` so the engine's route helpers resolve correctly:

```ruby
# config/routes.rb
mount Coplan::Engine, at: "/", as: "coplan"
```

Missing Coplan documents render a simple 404 page with navigation in the regular header.
The puzzle-piece icon below the glass panel opens an optional path puzzle. Preview it at `/_/not-found` (include
your mount prefix). Navigation works without JavaScript.

To use this page for unmatched HTML routes across the host too, add this to
the host's `config/application.rb`:

```ruby
config.exceptions_app = Coplan::ExceptionsApp.new(Rails.root.join("public"))
```

This page uses the regular application layout, including the signed-in viewer's
navigation, mode and theme. Visitors without a session can still use it. Other error statuses and
non-HTML errors retain Rails' public error handling. Development still shows
Rails' detailed routing exceptions; use the preview URL to try the design.
Keep a static `public/404.html` as a fallback for web servers serving errors
without Rails. The example host includes one.

### 3. Install migrations

```bash
bin/rails coplan:install:migrations
bin/rails db:migrate
```

This creates the engine's tables (`coplan_users`, `coplan_plans`, etc.) in your database.

> **Note:** The engine auto-appends its migration paths at boot, so you can skip `coplan:install:migrations` if you prefer — `db:migrate` will pick them up automatically. Use `install:migrations` if you want local copies you can inspect or modify.

### 4. Install required reference data

```bash
bin/rails coplan:seed
```

Coplan needs built-in reference rows such as the **General** plan type and
known agent harnesses. Replaying every migration creates them, but databases
initialized from a checked-in schema (`db:schema:load`, `db:prepare`,
`db:setup`) skip data migrations — the tables exist and the migrations are
marked applied, but the rows are missing.

`coplan:seed` is idempotent and never overwrites plan types or agent harnesses
you've customized. Run it after setup and after each engine version bump so
new reference rows are installed. Alternatively, call
`Coplan::Engine.load_seed` from your own `db/seeds.rb` so `db:setup` and
`db:seed` cover it automatically.

### Optional development demo library

The engine packages a curated demo library independently of required reference
data. In a development or test database, run:

```bash
COPLAN_DEMO_BASE_URL=http://localhost:3000/coplan bin/rails coplan:demo:seed
```

Use your actual host URL and engine mount path. This creates fixed example
users, presentations, design documents, version history, and approval states.
It refuses to run outside development and test. It needs no Faker dependency.
The engine does not install a login flow: your development authentication
callback must map to the seeded identities such as `seed:hampton`. Email-only
login as `hampton@example.com` is provided by this repository's example host.

See [the demo library guide](DEMO_LIBRARY.md) for the scenario list and how to
extend it. Keep demo seeding separate from production reference-data setup.

### 5. Configure authentication

Provide an `authenticate` callback that receives a Rack request and returns user identity attributes (or `nil` if unauthenticated):

```ruby
# config/initializers/coplan.rb
Coplan.configure do |config|
  config.authenticate = ->(request) {
    # Example: session-based auth
    user_id = request.session[:user_id]
    return nil unless user_id

    user = User.find_by(id: user_id)
    return nil unless user

    {
      external_id: user.id.to_s,   # required — unique ID from your auth system
      name: user.name,             # required — display name
      admin: user.admin?,          # optional — can manage Coplan settings (default: false)
      metadata: {}                 # optional — arbitrary data (default: {})
    }
  }

  # Optional: AI provider configuration
  config.ai_api_key = ENV["OPENAI_API_KEY"]
  config.ai_model = "gpt-4o"
  config.ai_models = { low: "gpt-6-luna" } # default for summaries; hosts can override
end
```

The callback is called on every Coplan request. The engine automatically finds or creates a `Coplan::User` from the returned attributes, keeping the name and admin flag in sync.

### Callback return values

| Key           | Type    | Required | Description |
|---------------|---------|----------|-------------|
| `external_id` | String  | Yes      | Unique identifier from your auth system |
| `name`        | String  | Yes      | Display name |
| `admin`       | Boolean | No       | Can manage reviewers, settings (default: `false`) |
| `metadata`    | Hash    | No       | Arbitrary data stored as JSON (default: `{}`) |

Return `nil` to indicate the user is not authenticated (the engine will respond with `401 Unauthorized`).

### Shared administration

Hosts using ActiveAdmin can load the Coplan admin screens and add their own
resources to the same menu. ActiveAdmin remains an optional host dependency;
the engine does not require it for its regular UI.

```ruby
# Gemfile
gem "activeadmin", "~> 4.0.0.beta"
gem "activeadmin_assets"

# config/initializers/active_admin.rb, inside ActiveAdmin.setup
Coplan::Admin.install!(config)

# config/routes.rb, before mounting Coplan::Engine
ActiveAdmin.routes(self)
```

The default URL is `/_/admin`. If Coplan is mounted under `/coplan`, pass
`path: "coplan/_/admin"` to `install!`. Every host registration in `app/admin`
joins the same namespace by default, so a host can add a model or custom page
without copying engine registrations. The host's `authenticate` callback
supplies the admin flag; the shared admin checks it again on every request.
It rejects signed-in non-admins even if the host has a permissive edge route.

## Authentication examples

### Devise

```ruby
config.authenticate = ->(request) {
  env = request.env
  warden = env["warden"]
  user = warden&.user
  return nil unless user

  {
    external_id: user.id.to_s,
    name: user.name,
    admin: user.admin?
  }
}
```

## Coplan::User model

The engine manages a `coplan_users` table with these columns:

| Column        | Type    | Description |
|---------------|---------|-------------|
| `id`          | String  | UUIDv7 primary key (auto-assigned) |
| `external_id` | String  | Unique ID from your auth system |
| `name`        | String  | Display name |
| `admin`       | Boolean | Admin flag |
| `metadata`    | JSON    | Host directory data; not Coplan settings |
| `app_theme` | String | Engine-owned app theme: `default` (follow `config.default_theme`) or a `Coplan::Themes` key |
| `theme_preference` | String | Engine-owned light/dark mode: system, light, or dark |
| `voice_hotkey` | String | Engine-owned push-to-talk preference |

`Coplan::User` is a normal ActiveRecord model. Host apps can reference it directly:

```ruby
class Notification < ApplicationRecord
  belongs_to :user, class_name: "Coplan::User"
end
```

## File attachments (ActiveStorage)

Plans support file attachments (images, PDFs, text/CSV/JSON, ZIP — max 25 MB per file), built on ActiveStorage.

### Migrations

The engine ships the ActiveStorage table migrations (`active_storage_blobs`, `active_storage_attachments`, `active_storage_variant_records`) alongside its own migrations, so they're installed the same way:

```bash
bin/rails coplan:install:migrations
bin/rails db:migrate
```

The engine's copy differs from the stock Rails install migration in one way: `active_storage_attachments.record_id` is a `string(36)` column so it can hold Coplan's UUID primary keys. The migration is guarded with `table_exists?` checks, so it's a no-op if your app already has ActiveStorage installed.

> **Warning:** If your app already has ActiveStorage with a **bigint** `record_id`, Coplan attachments won't work — the polymorphic `record_id` column can't store Coplan's string UUIDs. You'll need to widen the column to `string(36)` (existing integer IDs will store fine as strings, but verify any raw-SQL queries you have against that table).

### Storage service

Configure a storage service per environment (this is standard Rails — see the [ActiveStorage guide](https://guides.rubyonrails.org/active_storage_overview.html)):

```yaml
# config/storage.yml
local:
  service: Disk
  root: <%= Rails.root.join("storage") %>

amazon:
  service: S3
  access_key_id: <%= Rails.application.credentials.dig(:aws, :access_key_id) %>
  secret_access_key: <%= Rails.application.credentials.dig(:aws, :secret_access_key) %>
  region: us-east-1
  bucket: your-bucket-<%= Rails.env %>
```

```ruby
# config/environments/production.rb
config.active_storage.service = :amazon   # or :local for single-node Disk storage
```

The local `Disk` service is fine for development and single-node deployments (make sure `storage/` is on a persistent volume). Use S3 (add `gem "aws-sdk-s3"`) or another cloud service for multi-node production deployments.

## API tokens

Coplan provides a REST API for programmatic access. Users create API tokens in the Settings UI. API requests authenticate via `Authorization: Bearer <token>` headers — no session or callback required.

## Layout and sign-out

Coplan inherits from your `::ApplicationController` for layout and middleware. The engine's nav bar will render a "Sign out" link if your app defines a `sign_out_path` route helper.

## AI failure diagnostics

Chat and transcription errors append the provider's error type, code and message,
including gateway-specific reasons and plain-string gateway errors. The combined
diagnostic is limited to 300 characters and normalized to one line. Only string
fields are included; request objects and other fields are omitted. Providers are
trusted to supply suitable diagnostic text. Malformed bodies fall back to the
existing transport error, and the original exception remains available as the cause.

## Configuration reference

```ruby
Coplan.configure do |config|
  # Required
  config.authenticate = ->(request) { ... }

  # AI provider (optional) — powers plan summaries and dictated comments.
  # Any endpoint speaking the OpenAI wire protocol works: Azure OpenAI,
  # LiteLLM, vLLM, Ollama, an internal gateway. With no API key set, the
  # features that need one are skipped rather than erroring.
  config.ai_base_url = "https://api.openai.com/v1"  # default
  config.ai_api_key = nil
  config.ai_model = "gpt-4o"                         # fallback for all intensities
  config.ai_models = { low: "gpt-6-luna" }           # default; hosts can override each intensity
  config.summary_debounce_delay = 1.minute           # default quiet period after the last edit

  # Error reporting (optional)
  config.error_reporter = ->(exception, context) {
    Rails.error.report(exception, context: context)   # default
  }

  # Notifications (optional)
  config.notification_handler = ->(event, payload) { ... }
  config.notification_fanout_limit = 300           # nil disables the budget
  config.notification_fanout_window = 10.minutes   # positive whole seconds or duration

  # Analytics (optional)
  #
  # Fires for every event the engine instruments (page_view, plan_created,
  # plan_published, comment_created, thread_resolved, ...). Called inline on
  # the request thread; if your handler is slow, enqueue a job from inside it.
  # Exceptions raised by the handler are swallowed and reported via
  # `error_reporter`, so a broken sink will never break a user request.
  #
  # Payload always contains: :event, :timestamp, :user_id, :properties (Hash).
  config.track_event = ->(event, payload) {
    AnalyticsEvent.create!(name: event, payload: payload)
  }

  # App theme for everyone who hasn't picked one in Settings (optional).
  # One of Coplan::Themes.keys: "classic" or "neutral". See docs/THEMES.md.
  config.default_theme = "classic"                    # default
end
```

Text-generation calls can request `:low`, `:medium`, or `:high` intensity.
Each level uses `config.ai_models` when configured and otherwise falls back to
`config.ai_model`. Plan summaries request `:low`, which defaults to `gpt-6-luna`;
dictated comment cleanup and anchoring request `:medium`. Audio transcription
uses its own model, configured with `COPLAN_TRANSCRIBE_MODEL`.

Set `summary_debounce_delay` in the host initializer to a nonnegative duration
or number of seconds, such as `2.minutes` or `120`. Zero removes the wait.
Both new summary jobs and legacy jobs use this setting. Jobs already scheduled
are not moved earlier when the delay shrinks; jobs that wake before the current
quiet period ends reschedule for its end. Configure the same value in web and
worker processes.

## Notification delivery budget

By default, one person's comments can enqueue 300 external delivery jobs per
fixed ten-minute window. Each recipient costs one job per push subscription,
plus one dispatch job if delivery adapters are installed. Agents share their
person's budget across tokens and plans. Review notifications and events
without a Coplan user bypass this budget.

Set `notification_fanout_limit` to a positive integer, or `nil` to disable it.
Set `notification_fanout_window` to a positive whole number of seconds or a
duration such as `5.minutes`. Use the same settings in web and worker processes.
Changing the window starts a separate counter. The window is based on when
notifications are processed, not when a comment was posted.

When a recipient's delivery jobs do not fit, their inbox entry is still saved,
but their push and adapter delivery are skipped permanently. A warning names
the person and the budget. Rejected work does not consume the remaining budget.
The next window admits new work; it does not replay skipped deliveries. Jobs
already queued, their retries, and the host's `notification_handler` hook are
not limited. Multiple delivery adapters still count as one dispatch job.

The budget uses ordinary `Rails.cache` reads and writes, serialized with a lock
on the person's existing database row. It does not require cache counter support.
Use a shared, consistently readable cache such as Solid Cache or Redis across
processes. MemoryStore budgets are process-local. NullStore bypasses the budget.
Cache eviction, outages, and lock failures can relax this best-effort limit;
reported failures log a warning and allow delivery rather than interrupt inbox
creation. This is not a durable delivery quota or a replacement for queue capacity
planning. No additional tables or migrations are required.

## Suggested reviewers

Hosts can suggest who should review a plan, for example the owners of the code
it will change. Configure `suggest_reviewers` with a callable that receives a
`Coplan::Plan` and returns `Coplan::User` records, or hashes with `:user`, an
optional `:reason`, and an optional `:requirement` (`"required"` by default, or
`"optional"`):

```ruby
config.suggest_reviewers = ->(plan) {
  paths = plan.references.where(reference_type: "repository").pluck(:url)
  CodeOwners.lookup(paths).map do |owner|
    user = Coplan::User.find_by(username: owner.username)
    user && { user: user, reason: "Owns #{owner.path}", requirement: "required" }
  end.compact
}
```

Every link in a plan becomes a reference, so `plan.references` lists the
files, repositories, pull requests, and documents the plan names. GitHub file
links such as `https://github.com/org/repo/blob/main/app/models/user.rb` have
`reference_type` `"repository"`. Map people from your directory to existing
`Coplan::User` records; Coplan does not create users for suggestions.

The plan author sees suggestions under **Add reviewer**. Agents read them from
`GET /api/v1/plans/:id/review_requests/suggestions`. Suggestions only fill in
the choice: nobody is requested until the author or their agent requests them
through the usual review-request flow. Coplan leaves out the plan author,
people with an active review request, and duplicates.

The callback runs on the request thread each time the author opens **Add
reviewer** or an agent asks, so cache slow lookups inside it. Exceptions are
reported through `error_reporter`, and Coplan shows no suggestions.

## Connecting local agents without network authentication

When `config.api_authenticate` is unset, Coplan offers a browser approval flow
at `/_/agent/setup`. Local tools request a short-lived connection code, a person
approves using the host's existing browser login, and the local helper redeems
and stores one durable personal credential. Agents mint child session tokens
from it. GitHub/OIDC login stays in the host; Coplan does not need an OAuth
callback or webhook on the person's computer.

A configured `api_authenticate` hook disables these bootstrap endpoints and
hides the browser-connection prompt. Hosts supplying implicit network identity,
including Square, continue to mint sessions directly through that hook.

Serve the public setup guide, `agent-tools/coplan-connect`, and
`POST /api/v1/agent_connections{,/token}` to unauthenticated callers; they cannot
grant account access. `/_/agent/connect` displays the request, but approval is a
CSRF-protected POST using the host's human authentication. For signed-out people,
the approval page opens `config.sign_in_path` in a separate tab, then lets them
continue in the original tab. No return-URL contract is required from the host.

Use HTTPS and a shared Rails cache with atomic increments (such as Solid Cache)
for the per-IP start, polling, and verification rate limits across app workers.
Expired approval requests are pruned in batches on later starts. Tokens remain
in the normal personal-token and session history. Engine-owned parameter filters
redact both connection codes, and approval/token responses disable caching.
The helper stores the credential with mode 0600 without printing it. A second
host needs its own credentials file; the helper never overwrites another host's
configuration.

## Deleted comment retention

Ordinary comment deletion sets `deleted_at` and preserves the stored body. Public pages, notification previews, API responses, and queued agent event responses hide the text. Admins can inspect retained content under Plan Comments. The separate permanent deletion form requires a soft-deleted comment and explicit confirmation; it removes the comment and its associated copies. A metadata-only history entry records the admin who performed permanent deletion.

The historical `ScrubDeletedCommentBodies` migration now only adds the agent-event comment lookup index. Keep its historical migration version when updating an installed host copy, so Rails does not run the same migration twice. Replace any pending copy of the old destructive implementation before deploying this revision. Text erased by an earlier release cannot be recovered by migrating down.

Review notes also belong to immutable review receipts. Deleting the linked discussion comment does not change its receipt. The admin comment purge refuses these notes and leaves the receipt intact.
