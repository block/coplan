# CoPlan Engine — Host App Implementation Guide

This guide covers everything you need to mount the CoPlan engine in your own Rails application.

## Prerequisites

- Ruby 3.4+
- Rails 8.0+
- MySQL 8+
- A User model with string-based primary keys (UUID, ULID, etc.)

## 1. Add the Engine

Add the engine to your `Gemfile`. If CoPlan lives in a local directory or a Git repo:

```ruby
# Local path (monorepo or development):
gem "coplan", path: "engine"

# Git:
gem "coplan", git: "https://github.com/block/coplan.git", glob: "engine/*.gemspec"
```

Then run `bundle install`.

## 2. Run Migrations

CoPlan's tables are prefixed with `coplan_` and use string(36) primary keys. Copy and run the engine's migrations:

```bash
bin/rails coplan:install:migrations
bin/rails db:migrate
```

Tables created: `coplan_plans`, `coplan_plan_versions`, `coplan_comment_threads`, `coplan_comments`, `coplan_edit_leases`, `coplan_edit_sessions`, `coplan_plan_collaborators`, `coplan_api_tokens`, `coplan_automated_plan_reviewers`.

## 3. Configure the Engine

Create an initializer at `config/initializers/coplan.rb`:

```ruby
CoPlan.configure do |config|
  # Required: your User model class name (must be a string)
  config.user_class = "User"

  # Required: OpenAI API key for Cloud Persona reviewers
  config.ai_api_key = Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]

  # Optional: AI model (default: "gpt-4o")
  config.ai_model = "gpt-4o"

  # Optional: Base URL for AI API (default: "https://api.openai.com/v1")
  config.ai_base_url = "https://api.openai.com/v1"

  # Optional: error reporter (default: Rails.error.report)
  config.error_reporter = ->(exception, context) {
    Rails.error.report(exception, context: context)
  }

  # Optional: notification handler for events like :comment_created
  config.notification_handler = ->(event, payload) {
    case event
    when :comment_created
      # payload[:comment_thread_id] is available
      YourNotificationJob.perform_later(payload)
    end
  }
end
```

## 4. Prepare Your User Model

Include `CoPlan::UserModel` in your User model. This adds the associations CoPlan needs (`coplan_api_tokens`, `coplan_plan_collaborators`) and provides a default `can_admin_coplan?` method.

```ruby
class User < ApplicationRecord
  include CoPlan::UserModel

  # Required interface:
  #   #id   → String (UUID, ULID, or any unique string)
  #   #name → String (display name, shown in comments and versions)

  # Override to control who can manage Cloud Personas and settings:
  def can_admin_coplan?
    admin?
  end
end
```

Your User model's primary key must be a string type (e.g., `id: { type: :string, limit: 36 }`). CoPlan stores user IDs as foreign keys in its own tables.

## 5. Mount the Engine

In your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  # Mount at root — CoPlan provides its own dashboard, plans UI, and API
  mount CoPlan::Engine => "/"

  # Or mount under a path prefix:
  mount CoPlan::Engine => "/coplan"
end
```

The engine provides these route groups:

| Path | Purpose |
|------|---------|
| `/` | Dashboard |
| `/plans` | Plans UI (index, show, edit) |
| `/settings/tokens` | API token management |
| `/api/v1/plans` | REST API for agents |
| `/api/v1/plans/:id/lease` | Edit lease management |
| `/api/v1/plans/:id/operations` | Semantic edit operations |
| `/api/v1/plans/:id/comments` | Comment threads |

## 6. Authentication Contract

CoPlan inherits from your `ApplicationController` and expects these methods to be available:

```ruby
class ApplicationController < ActionController::Base
  # CoPlan calls these — you must implement them:

  def current_user
    # Must return a User instance (matching config.user_class) or nil
  end

  def signed_in?
    # Must return true/false
  end

  def authenticate_user!
    # Must redirect unauthenticated users to sign-in
    # CoPlan's web controllers call this via before_action
  end

  # CoPlan raises this when authorization fails (returns 404)
  class NotAuthorizedError < StandardError; end

  rescue_from NotAuthorizedError do
    head :not_found
  end
end
```

The API controllers handle their own authentication via `Authorization: Bearer <token>` headers using CoPlan's built-in API token system. No additional setup is needed.

## 7. Background Jobs

CoPlan uses ActiveJob for Cloud Persona reviews and session expiry. Configure a queue backend (SolidQueue recommended):

```ruby
# config/application.rb
config.active_job.queue_adapter = :solid_queue
```

Jobs used:
- `CoPlan::AutomatedReviewJob` — runs Cloud Persona reviews when plan status changes
- `CoPlan::CommitExpiredSessionJob` — auto-commits expired edit sessions
- `CoPlan::NotificationJob` — triggers the `notification_handler` callback

## 8. ActionCable (Realtime)

CoPlan broadcasts comments, edits, and status changes via Turbo Streams. Configure an ActionCable adapter (SolidCable recommended):

```yaml
# config/cable.yml
production:
  adapter: solid_cable
```

No additional channel setup is needed — the engine uses `Turbo::StreamsChannel` directly.

## 9. Seed Default Reviewers

CoPlan ships with default Cloud Persona reviewers (security, scalability, routing). Seed them:

```ruby
# db/seeds.rb
CoPlan::AutomatedPlanReviewer.create_defaults
```

Or call this from a rake task / console after deployment.

## 10. Customization

### Layout

CoPlan uses its own layout (`coplan/application`). It calls `main_app.sign_out_path` for the sign-out link. If your sign-out route has a different name, override the layout by creating `app/views/layouts/coplan/application.html.erb` in your host app.

### Styles

CoPlan ships a self-contained CSS file at `coplan/application.css`. It's scoped and does not depend on your host app's styles.

### Admin

If you use ActiveAdmin, CoPlan models can be registered for admin management. See the reference host app's `app/admin/` directory for examples of registering `CoPlan::Plan`, `CoPlan::ApiToken`, etc. Each model defines `ransackable_attributes` and `ransackable_associations` for search.

## Minimal Working Example

```ruby
# Gemfile
gem "coplan", path: "engine"

# config/initializers/coplan.rb
CoPlan.configure do |config|
  config.user_class = "User"
  config.ai_api_key = ENV["OPENAI_API_KEY"]
end

# app/models/user.rb
class User < ApplicationRecord
  include CoPlan::UserModel
end

# config/routes.rb
Rails.application.routes.draw do
  mount CoPlan::Engine => "/"
end
```

That's it. Run migrations, seed reviewers, and you have a working plan review system with AI-powered feedback.
