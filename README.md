# CoPlan

Engineering design doc review, purpose-built for AI-assisted planning. Built with Rails 8, Hotwire, and a semantic operations API.

> **Building a host app?** See the [Host App Implementation Guide](./docs/HOST_APP_GUIDE.md) for everything you need to mount the CoPlan engine.

## Why CoPlan?

Plans get better when more eyes see them. An engineer drafts a plan — often with AI help — and CoPlan gives it a home where teammates can review it, leave inline feedback, and iterate. Domain experts catch things the author missed. AI agents respond to feedback and apply edits automatically. The result is higher-quality plans before a single line of code is written.

**The editing model is intentionally asymmetric:** humans comment, AI agents edit. When a reviewer leaves feedback and the author accepts it, an agent applies the change — creating a new immutable version with full provenance (who changed what, why, and which comment triggered it). This keeps the version history clean and auditable.

## How It Works

- **Plans are Markdown documents** that move through a lifecycle: `brainstorm → considering → developing → live` (or `→ abandoned`). Brainstorm plans are private; once a plan moves to *considering*, it's published to the whole org.
- **Inline commenting** — select any text in the rendered plan to leave a comment, Google Docs-style. Comments are threaded and anchor to the selected text.
- **AI agents edit via semantic operations** — `replace_exact`, `insert_under_heading`, `delete_paragraph_containing` — not brittle line numbers. Agents acquire an edit lease (one at a time), submit operations against a base revision, and the server creates a new version.
- **Cloud Personas** — server-side AI reviewers (security, scalability, routing) that automatically review plans when they reach certain statuses, or on demand.
- **Realtime** — comments, edits, and status changes broadcast instantly to all viewers via Turbo Streams.
- **Full provenance** — every version records the actor (human, local agent, or cloud persona), the AI model used, the prompt, and which comments triggered the change.

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
