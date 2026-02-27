# CoPlan Host App Integration Guide

## Overview

CoPlan is a Rails engine that manages collaborative planning documents. It owns its own `CoPlan::User` model and handles authentication internally via a callback you configure.

## Setup

### 1. Mount the engine

```ruby
# config/routes.rb
mount CoPlan::Engine, at: "/coplan"
```

You can also mount at the root if CoPlan is the primary purpose of your app. When doing so, add `as: "coplan"` so the engine's route helpers resolve correctly:

```ruby
# config/routes.rb
mount CoPlan::Engine, at: "/", as: "coplan"
```

### 2. Install migrations

```bash
bin/rails coplan:install:migrations
bin/rails db:migrate
```

This creates the engine's tables (`coplan_users`, `coplan_plans`, etc.) in your database.

> **Note:** The engine auto-appends its migration paths at boot, so you can skip `coplan:install:migrations` if you prefer — `db:migrate` will pick them up automatically. Use `install:migrations` if you want local copies you can inspect or modify.

### 3. Configure authentication

Provide an `authenticate` callback that receives a Rack request and returns user identity attributes (or `nil` if unauthenticated):

```ruby
# config/initializers/coplan.rb
CoPlan.configure do |config|
  config.authenticate = ->(request) {
    # Example: session-based auth
    user_id = request.session[:user_id]
    return nil unless user_id

    user = User.find_by(id: user_id)
    return nil unless user

    {
      external_id: user.id.to_s,   # required — unique ID from your auth system
      name: user.name,             # required — display name
      admin: user.admin?,          # optional — can manage CoPlan settings (default: false)
      metadata: {}                 # optional — arbitrary data (default: {})
    }
  }

  # Optional: AI provider configuration
  config.ai_api_key = ENV["OPENAI_API_KEY"]
  config.ai_model = "gpt-4o"
end
```

The callback is called on every CoPlan request. The engine automatically finds or creates a `CoPlan::User` from the returned attributes, keeping the name and admin flag in sync.

### Callback return values

| Key           | Type    | Required | Description |
|---------------|---------|----------|-------------|
| `external_id` | String  | Yes      | Unique identifier from your auth system |
| `name`        | String  | Yes      | Display name |
| `admin`       | Boolean | No       | Can manage reviewers, settings (default: `false`) |
| `metadata`    | Hash    | No       | Arbitrary data stored as JSON (default: `{}`) |

Return `nil` to indicate the user is not authenticated (the engine will respond with `401 Unauthorized`).

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

## CoPlan::User model

The engine manages a `coplan_users` table with these columns:

| Column        | Type    | Description |
|---------------|---------|-------------|
| `id`          | String  | UUIDv7 primary key (auto-assigned) |
| `external_id` | String  | Unique ID from your auth system |
| `name`        | String  | Display name |
| `admin`       | Boolean | Admin flag |
| `metadata`    | JSON    | Extensible data bag |

`CoPlan::User` is a normal ActiveRecord model. Host apps can reference it directly:

```ruby
class Notification < ApplicationRecord
  belongs_to :user, class_name: "CoPlan::User"
end
```

## API tokens

CoPlan provides a REST API for programmatic access. Users create API tokens in the Settings UI. API requests authenticate via `Authorization: Bearer <token>` headers — no session or callback required.

## Layout and sign-out

CoPlan inherits from your `::ApplicationController` for layout and middleware. The engine's nav bar will render a "Sign out" link if your app defines a `sign_out_path` route helper.

## Configuration reference

```ruby
CoPlan.configure do |config|
  # Required
  config.authenticate = ->(request) { ... }

  # AI provider (optional)
  config.ai_base_url = "https://api.openai.com/v1"  # default
  config.ai_api_key = nil
  config.ai_model = "gpt-4o"                         # default

  # Error reporting (optional)
  config.error_reporter = ->(exception, context) {
    Rails.error.report(exception, context: context)   # default
  }

  # Notifications (optional)
  config.notification_handler = ->(event, payload) { ... }
end
```
