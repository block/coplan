# CoPlan

A collaborative planning tool where humans and AI agents co-author living documents. Built with Rails 8, Hotwire, and a semantic operations API.

## What It Does

Teams write plans in Markdown. AI agents (local or cloud) review, comment on, and edit those plans through the same API. Every edit is versioned. Comments anchor to selected text (Google Docs-style). Realtime updates via Turbo Streams.

## Tech Stack

- **Ruby on Rails 8+** — importmaps, Hotwire, Stimulus
- **MySQL 8+** — UUID primary keys
- **SolidQueue** — background jobs
- **SolidCable** — ActionCable adapter

## Setup

```bash
bin/setup
bin/rails db:seed
bin/dev
```

Sign in with any `@example.com` email (stub OIDC).

## Tests

```bash
bin/rails test
```

## API

Agents authenticate with `Authorization: Bearer <token>`. Key endpoints:

- `GET /api/v1/plans/:id` — read a plan
- `POST /api/v1/plans/:id/lease` — acquire edit lease
- `POST /api/v1/plans/:id/operations` — apply semantic edits
- `POST /api/v1/plans/:id/comments` — comment on a plan

See [docs/PLAN.md](./docs/PLAN.md) for full architecture.

## Project Resources

| Resource | Description |
|----------|-------------|
| [CODEOWNERS](./CODEOWNERS) | Project lead(s) |
| [GOVERNANCE.md](./GOVERNANCE.md) | Project governance |
| [LICENSE](./LICENSE) | Apache License, Version 2.0 |
