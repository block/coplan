# CoPlan — Concept

## What Is This?

CoPlan is an open-source Rails application for managing the **Plan** phase of AI-assisted development workflows. When engineers use the Research → Plan → Implement (RPI) method with AI agents, the Plan phase produces Markdown documents — often living only on a local machine. CoPlan gives those documents a home where teammates can review them, leave inline feedback, and iterate on them with AI assistance.

Think of it as **engineering design doc review, but purpose-built for AI-generated plans**.

## Goals

- Centralize plan documents into a reviewable, shareable system
- Enable line-level inline commenting and threaded discussion
- Let AI agents assist with iteration: responding to feedback, proposing edits, applying changes
- Maintain strong version history with full provenance (what changed, why, who, what prompted it)
- Provide realtime collaboration via Turbo Streams
- Keep the frontend simple: Rails + Turbo + Stimulus + plain CSS/JS, no bundling

## Non-Goals

- Full Google Docs-style collaborative editing (humans comment, agents edit)
- General-purpose wiki or knowledge base
- Code review replacement (this is for planning docs, not code)
- Real-time multi-author direct editing of plan body text
- CRDT-based editing in v1 (revisit if concurrent editing demand is proven)

## Tech Stack

- **Backend:** Ruby on Rails
- **Frontend:** Plain CSS, plain JavaScript, Stimulus.js, Turbo (Turbo Streams, Turbo Drive, Turbo Frames)
- **No bundler** — importmaps or direct script tags
- **Database:** PostgreSQL (assumed)
- **AI Providers:** OpenAI, Gemini, etc. via a provider abstraction layer

## Roles

| Role | Can Do |
|------|--------|
| **Author** | Creates/uploads plans, requests reviews, accepts feedback, triggers agent edits |
| **Reviewer** | Leaves line-level comments, approves/requests changes, suggests other reviewers |
| **Agent** | Replies to comment threads, proposes edits, applies accepted changes |
| **Admin** | Manages auth, AI provider configs, org settings |

## Document Lifecycle

```
Brainstorm → Considering → Developing → Live
                                          ↘
                                        Abandoned
```

- **Brainstorm** — Early ideas, private by default (need direct URL or invite to view)
- **Considering** — Under active review, published to the Org
- **Developing** — Plan accepted, implementation in progress, published to the Org
- **Live** — The design is implemented and real, published to the Org
- **Abandoned** — Plan was scrapped or went stale (auto-archive after inactivity?)

Status transitions are decided by the Author (+ their agent). No formal approval gates — this is intentionally lightweight. In practice, ~80% of plans will end up Abandoned.

### Visibility Rules

- **Brainstorm** plans are **private** — only accessible via direct URL or explicit invite
- **Considering / Developing / Live** plans are **published** to the entire Org
- Published plans are tagged and browsable by **service**, **OS/platform**, **date**, and other metadata

## Core Workflow

1. **Create a Plan** — Author (often assisted by a local AI agent) writes a Markdown plan and uploads it to CoPlan
2. **Request Review** — Author invites teammates to review the plan
3. **Inline Feedback** — Reviewers leave line-level comments on any part of the document, threaded discussions develop
4. **Agent Assistance** — AI agents can:
   - Reply to comment threads with analysis, alternatives, or risk callouts
   - Generate proposed edits to the document
   - Apply edits to create a new version (when authorized by the Author)
5. **Accept & Iterate** — Author reviews feedback, accepts or dismisses comments, and triggers agent edits as needed
6. **Version History** — Every change is recorded as an immutable version with full metadata

## Editing Model

**Humans do not directly edit the plan document.** The workflow is:

1. A human leaves a comment (feedback, suggestion, concern)
2. The Author accepts the feedback
3. An AI agent applies the edit, creating a new version — no preview/approve step, it "just happens"

This keeps the version history clean and auditable — every change has a clear "why" tied to a comment or prompt.

Only one agent edits a document at a time. The server enforces this with a simple edit lease/lock with a TTL. Humans can comment freely while an agent holds the edit lease. This avoids conflict resolution complexity entirely for v1.

## Versioning & Provenance

Every version of a document is stored with:

- **Full content snapshot** of the Markdown
- **Computed diff** from the previous version
- **Change summary** — what changed in plain language
- **Reason** — which comment(s) or prompt triggered the change
- **Actor** — who or what made the change (user ID or agent identity)
- **Model/provider info** — if an AI made the change, which model and provider
- **Timestamp**

Versions are immutable once created. The full history is always available and browsable.

## Line-Level Commenting

- Comments attach to specific lines or ranges of the Markdown document
- Comments are threaded (replies supported)
- Comments can be resolved/accepted by the Author
- When the document is edited, comments are marked as **"out of date"** — they remain visible but flagged, with a link back to the version they were made on
- No attempt at automatic re-anchoring (keep it simple)

## Local ↔ Remote Sync

The document's **source of truth is the database**. Local interaction happens via:

- **Upload/Import** — Push a local `.md` file to create or update a plan
- **Download/Export** — Pull the latest version to disk
- **CLI tool or Agent Skill** — Makes push/pull trivial from the command line or from an AI agent

Edits (whether from a local agent or the cloud) go through a **server-authoritative operation-based API**. Agents submit operations against a specific base revision, and the server applies them, increments the revision, stores the audit trail, and broadcasts via Turbo Streams.

If a submitted edit references a stale revision, the server returns a **409 Conflict** with the latest content so the agent can re-plan.

Future consideration: CRDT-based editing if concurrent multi-agent editing demand is proven. For now, the single-agent lease + revision-based API is sufficient.

## Realtime Updates

The web interface uses **Turbo Streams** for realtime updates:

- New comments appear instantly for all viewers
- Status changes broadcast to all viewers
- New versions appear in the version history live
- Comment resolution state updates in realtime

## Authentication & Authorization

- **OpenID Connect** — Optional, for SSO integration (e.g., internal Square/Block deployment)
- **Auth Tokens** — API tokens for agent and CLI connections
- **Permissions** — Role-based access per plan (Author, Reviewer, Viewer)

### Organizations & Multi-Tenancy

- Plans belong to an **Organization**
- Orgs define allowed email domains (e.g., `squareup.com`, `block.xyz`) for membership
- Users cannot sign up without belonging to a configured Org domain
- Could support a public hosted instance in the future, but initially Org membership is required

## AI Features

### Agent-Applied Edits
- Agents submit operations against a specific base revision via the editing API
- Operations are semantic, not line-number-based (line numbers are brittle). Examples:
  - `replace_exact` — find exact text and replace it
  - `insert_under_heading` — insert content below a named heading
  - `delete_paragraph_containing` — remove a paragraph matching a needle
  - `apply_unified_diff` — apply a standard unified diff (power tool)
- The server validates operations apply cleanly, creates a new immutable version, and broadcasts via Turbo Streams
- Each edit records full provenance (actor, prompt, model, linked comments)

### "Ask an Agent" (Web UI)
- Users can ask questions about a plan document from the web interface
- Example: "Explain what this document covers for testing"
- The system finds relevant lines, sends context to an AI provider, and returns a focused explanation with line citations

### Cloud Personas (Pre-Built Reviewer Prompts)

Cloud Personas are **server-side prompt templates** — not real agents. They are the service itself, running as **SolidQueue background jobs** that call external LLMs with pre-set prompts.

Examples:
- **Scalability Reviewer** — Analyzes the plan for scaling concerns
- **Security Reviewer** — Flags potential security implications
- **Routing Reviewer** — Suggests which human experts should review based on content

Cloud Personas are distinct actors in the audit trail (separate from a user's local agent). They can be triggered manually by the Author or automatically when a plan enters "Considering" status.

For v1, Persona prompts are **literal files in the Rails project repo**, managed via normal GitHub changes. The `AutomatedPlanReviewer` model has a real UUID and references which prompt file to use. This keeps things simple — no prompt editor UI needed yet.

### AI Provider Abstraction
- Support multiple providers (OpenAI, Gemini, etc.) behind a unified interface
- Provider configuration managed by admins (API keys, model selection, rate limits)
- All prompts and responses can be logged for audit purposes

### Actor Types in Audit Trail

| Actor | Description | Auth |
|-------|-------------|------|
| **Human** | A user leaving comments or triggering actions | OIDC / session |
| **Local Agent** | An AI agent on the user's machine (Amp, Cursor, etc.) | API token (scoped to user) |
| **Cloud Persona** | A server-side prompt template running as a SolidQueue job | Internal — the service itself |

## REST API (for Local Agents & CLI)

```
GET    /api/v1/plans/:uuid                → read current doc + metadata
GET    /api/v1/plans/:uuid/versions       → list versions
POST   /api/v1/plans                      → create a plan
POST   /api/v1/plans/:uuid/operations     → submit edit operations (with base_revision)
GET    /api/v1/plans/:uuid/comments       → read comments
POST   /api/v1/plans/:uuid/comments       → add a comment
PATCH  /api/v1/plans/:uuid                → update status, tags, metadata
```

Authenticated via API tokens scoped to a user. Stateless request/response — agents are invoked, do their work, and exit. The bulk of ongoing work (post-push reviews, feedback) is handled by Cloud Personas server-side.

## Notifications

- **Slack** — Primary notification channel (new comments, status changes, review requests)
- **In-app** — Notification feed within CoPlan
- Email is not planned for v1

## Decided

| Question | Decision |
|----------|----------|
| Can humans edit directly? | No. Humans comment, agents edit. |
| Agent edit approval? | No preview step — edits "just happen" when triggered. |
| Concurrent agents? | One agent at a time (edit lease with TTL). Revisit with CRDTs if needed. |
| Status gates? | No formal gates. Author + agent decide. |
| Data residency? | Content can be sent to approved external AI providers. |
| Multi-tenancy? | Orgs with domain-matching for membership. |
| Comment anchoring? | Comments become "out of date" after edits. No re-anchoring. |
| Source of truth? | Database. Push/pull for local sync. |
| Edit format? | Semantic operations (replace_exact, insert_under_heading, etc.) against a base revision. |
| IDs? | UUIDs everywhere. |
| Visibility? | Brainstorm = private (URL/invite). Considering+ = published to Org. Tagged by service/OS/date. |
| Notifications? | Slack + in-app. No email for v1. |
| Cloud Personas? | Server-side prompts running as SolidQueue jobs. Distinct actors in audit trail. Not authenticated — they ARE the service. |
| Abandoned state? | Yes. Auto-archive after inactivity. |
| Slack integration? | Notifications only. No slash commands for v1. |
| Cloud Personas? (management) | Prompt files in the repo, edited via GitHub. AutomatedPlanReviewer model with real UUIDs, but prompts are just files on disk for now. |
| API for local agents? | REST only. No WebSocket/SSE. Agents are invoked, do work, exit. |
| Who does post-push work? | Mostly Cloud Personas (Automated Plan Reviewers) via SolidQueue. Local agents only for big changes or implementation-time updates. |

## Open Questions

> These need to be resolved before moving from Concept to a formal Plan.

1. **Repo linking** — Plans can link to multiple repos/branches/PRs. Just metadata for v1, auto-linking via webhooks is a future feature.
2. **Scale expectations** — How many documents, how large, how many concurrent users per org?
3. **Tagging taxonomy** — TBD. Possibly agent-defined. Open for later phases.
4. **Auto-archive timing** — How long without activity before a Brainstorm plan is auto-archived to Abandoned?
