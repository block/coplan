# CoPlan — Implementation Plan

> Status: **Brainstorm**
> Parent: [CONCEPT.md](./CONCEPT.md)

## Tech Stack (Locked In)

- **Ruby on Rails 8+** — importmaps, no bundler
- **Hotwire** — Turbo Drive, Turbo Frames, Turbo Streams, Stimulus
- **SolidQueue** — background jobs (Cloud Personas, notifications)
- **SolidCable** — ActionCable adapter for Turbo Streams
- **PostgreSQL** (primary) or **MySQL 8+** — UUID primary keys everywhere. Schema is portable across both.
- **Plain CSS** — no Tailwind, no preprocessor
- **Plain JavaScript** — via importmaps, Stimulus controllers only

### Gems

| Gem | Purpose |
|-----|---------|
| `commonmarker` | Markdown → HTML rendering |
| `diffy` | Readable diffs between versions |
| `ruby-openai` | AI provider client (start with one, abstract later) |
| `activeadmin` | Admin interface (v4.0.0.beta20+) |
| `activeadmin_assets` | Pre-compiled AA assets — no node/tailwind/bundler needed |
| `rack-attack` | API rate limiting (Phase 9) |

No gems for auth — stub OIDC in dev (email-only login), hand-rolled real OIDC in Phase 9 (~50 lines, `Net::HTTP`). No Devise, no OmniAuth.

No gems for Slack — use `Net::HTTP` to post to incoming webhooks.

---

## Data Models

### Global Conventions

- All tables use `id: :uuid` primary keys
- All multi-tenant tables include `organization_id` (FK, not null)
- Enums are stored as strings (not integers) to avoid coupling
- `Current.organization` and `Current.user` set per-request for scoping
- Schema avoids PG-only features (no `citext`, no `text[]`, no `ON CONFLICT ... WHERE`) — use Rails-level validations and `serialize`/`json` columns instead for portability

### `organizations`

```
id:                    uuid PK
name:                  string, not null
slug:                  string, not null, unique
allowed_email_domains: json, not null, default: []    (e.g. ["squareup.com", "block.xyz"])
slack_webhook_url:     text, nullable
created_at/updated_at
```

### `users` (no passwords — OIDC only, stubbed in dev)

```
id:                uuid PK
organization_id:   uuid FK → organizations, not null
email:             string, not null  (uniqueness enforced case-insensitively at app level)
name:              string, not null
org_role:          string, not null, default: "member"  (member | admin)
oidc_provider:     string, nullable
oidc_sub:          string, nullable
last_sign_in_at:   timestamp, nullable
created_at/updated_at

unique index: (organization_id, email)
```

**Two auth paths:**
- **Web (humans):** OIDC flow → session cookie. In dev, a stub OIDC controller accepts any email from an allowed domain and creates a session immediately (no real provider needed).
- **API (local agents):** `Authorization: Bearer <token>` header, validated against `api_tokens.token_digest`. Stateless, no sessions.

Domain matching: on sign-in, extract email domain and verify it's in `organization.allowed_email_domains`.

### `plans`

```
id:                      uuid PK  (also the URL slug — to_param returns id)
organization_id:         uuid FK → organizations, not null
title:                   string, not null
status:                  string, not null, default: "brainstorm"
                         (brainstorm | considering | developing | live | abandoned)
current_plan_version_id: uuid FK → plan_versions, nullable
current_revision:        integer, not null, default: 0
tags:                    json, not null, default: []
metadata:                json, not null, default: {}
created_by_user_id:      uuid FK → users, not null
created_at/updated_at

index: (organization_id, status)
index: (organization_id, updated_at)
```

**Visibility rule (enforced in authorization layer):**
- `brainstorm` → only author + explicit collaborators can see
- `considering`, `developing`, `live`, `abandoned` → all org members can see

### `plan_versions`

Immutable. Never updated or deleted.

```
id:                uuid PK
plan_id:           uuid FK → plans, not null
organization_id:   uuid FK → organizations, not null
revision:          integer, not null
content_markdown:  text, not null
content_sha256:    string, not null
diff_unified:      text, nullable  (from previous version)
change_summary:    text, nullable  (plain English description)
reason:            text, nullable  (which comment/prompt triggered this)

# Provenance
actor_type:        string, not null  (human | local_agent | cloud_persona | system)
actor_id:          uuid, nullable
                   human → users.id
                   local_agent → api_tokens.id
                   cloud_persona → automated_plan_reviewers.id

# AI metadata (nullable — only set for AI-generated versions)
ai_provider:       string, nullable
ai_model:          string, nullable
prompt_excerpt:    text, nullable

# Operation trace
operations_json:   json, not null, default: []
base_revision:     integer, nullable

created_at

unique index: (plan_id, revision)
index: (plan_id, created_at)
```

### `comment_threads`

```
id:                              uuid PK
plan_id:                         uuid FK → plans, not null
organization_id:                 uuid FK → organizations, not null
plan_version_id:                 uuid FK → plan_versions, not null  (anchor version)
start_line:                      integer, nullable
end_line:                        integer, nullable
                                 (both null = general/non-line-specific thread)
status:                          string, not null, default: "open"
                                 (open | resolved | accepted | dismissed)
out_of_date:                     boolean, not null, default: false
out_of_date_since_version_id:    uuid FK → plan_versions, nullable
addressed_in_plan_version_id:    uuid FK → plan_versions, nullable
created_by_user_id:              uuid FK → users, not null
resolved_by_user_id:             uuid FK → users, nullable
created_at/updated_at

index: (plan_id, status)
index: (plan_id, out_of_date)
```

**Out-of-date rule:** When a new `PlanVersion` is created, all `CommentThread`s with `plan_version_id != new_version_id` and `out_of_date = false` get marked `out_of_date = true`.

### `comments`

```
id:                uuid PK
comment_thread_id: uuid FK → comment_threads, not null
organization_id:   uuid FK → organizations, not null
author_type:       string, not null  (human | local_agent | cloud_persona | system)
author_id:         uuid, nullable
body_markdown:     text, not null
created_at/updated_at

index: (comment_thread_id, created_at)
```

### `plan_collaborators`

```
id:              uuid PK
plan_id:         uuid FK → plans, not null
organization_id: uuid FK → organizations, not null
user_id:         uuid FK → users, not null
role:            string, not null  (author | reviewer | viewer)
added_by_user_id: uuid FK → users, nullable
created_at/updated_at

unique index: (plan_id, user_id)
```

### `api_tokens`

```
id:              uuid PK
organization_id: uuid FK → organizations, not null
user_id:         uuid FK → users, not null
name:            string, not null
token_digest:    string, not null  (SHA256 of the raw token)
last_used_at:    timestamp, nullable
expires_at:      timestamp, nullable
revoked_at:      timestamp, nullable
created_at/updated_at

unique index: (token_digest)
index: (user_id)
```

Raw token shown once on creation, never stored. All API auth compares `SHA256(provided_token)` against `token_digest`.

### `edit_leases`

One row per plan (upserted, not inserted fresh each time).

```
id:                 uuid PK
plan_id:            uuid FK → plans, not null, unique
organization_id:    uuid FK → organizations, not null
holder_type:        string, not null  (local_agent | cloud_persona | system)
holder_id:          uuid, nullable
lease_token_digest: string, not null
expires_at:         timestamp, not null
last_heartbeat_at:  timestamp, not null
created_at/updated_at

unique index: (plan_id)
```

**Lease acquisition** — transaction with row lock (portable across PG and MySQL):
```ruby
ActiveRecord::Base.transaction do
  lease = EditLease.lock.find_by(plan_id: plan.id)
  if lease && lease.expires_at > Time.current && lease.lease_token_digest != current_digest
    raise EditLease::Conflict  # → 409
  end
  lease ||= EditLease.new(plan_id: plan.id, organization_id: plan.organization_id)
  lease.update!(holder_type:, holder_id:, lease_token_digest:, expires_at: 5.minutes.from_now, last_heartbeat_at: Time.current)
  lease
end
```

Returns 409 if the lease is held by someone else and not expired.

### `automated_plan_reviewers`

```
id:               uuid PK
organization_id:  uuid, nullable  (null = global/built-in)
key:              string, not null  (slug, e.g. "security-reviewer")
name:             string, not null
prompt_path:      string, not null  (relative to Rails.root, e.g. "prompts/reviewers/security.md")
enabled:          boolean, not null, default: true
trigger_statuses: json, not null, default: []  (e.g. ["considering"])
ai_provider:      string, not null, default: "openai"
ai_model:         string, not null
created_at/updated_at

unique index: (organization_id, key)
```

### `notifications`

```
id:                uuid PK
organization_id:   uuid FK → organizations, not null
recipient_user_id: uuid FK → users, not null
event_type:        string, not null
title:             string, not null
body:              text, nullable
target_type:       string, nullable  (polymorphic: "Plan", "CommentThread", etc.)
target_id:         uuid, nullable
read_at:           timestamp, nullable
created_at/updated_at

index: (recipient_user_id, read_at)
index: (recipient_user_id, created_at)
```

---

## Semantic Operations Engine

The operations endpoint accepts a JSON array of operations applied sequentially to the current document content. All operations are **deterministic string manipulations** — no Markdown AST parsing required for v1.

Service: `Plans::ApplyOperations.call(content:, operations:)` → returns `{ content:, applied: [] }` or raises `Plans::OperationError`.

### `replace_exact`

Find an exact substring and replace it. Fails if the substring appears 0 times or more than `count` times.

```json
{
  "op": "replace_exact",
  "old_text": "We should use MySQL",
  "new_text": "We should use PostgreSQL",
  "count": 1
}
```

Implementation: `String#scan` to count occurrences, `String#sub` or `String#gsub` to replace.

### `insert_under_heading`

Insert content after a Markdown heading. Fails if the heading isn't found or is ambiguous.

```json
{
  "op": "insert_under_heading",
  "heading": "## Testing Strategy",
  "content": "\n- Add integration tests for the API layer\n- Mock external AI providers\n"
}
```

Implementation: regex `^#{Regexp.escape(heading)}\s*$` to find the heading line, insert content after it (preserving a blank line separator).

### `delete_paragraph_containing`

Delete the paragraph (block of text separated by blank lines) containing a needle string. Fails if 0 or >1 paragraphs match.

```json
{
  "op": "delete_paragraph_containing",
  "needle": "This approach is deprecated"
}
```

Implementation: split on `/\n{2,}/`, find matching paragraph, remove it, rejoin with `\n\n`.

### Future: `apply_unified_diff`

Deferred. Unified diffs are powerful but fragile — misapplication produces subtly broken documents. The three operations above cover the vast majority of agent edit patterns.

---

## Turbo Streams Broadcasting

Stream channel per plan: `turbo_stream_from(plan)`

| Event | Broadcast Action |
|-------|-----------------|
| New comment | `broadcast_append_to` thread's comment list |
| Thread status change | `broadcast_replace_to` thread header partial |
| Threads marked out-of-date | `broadcast_replace_to` threads list |
| New version created | `broadcast_replace_to` current content + `broadcast_prepend_to` version list |
| Plan status change | `broadcast_replace_to` plan header |

---

## Cloud Persona Job Flow

```
1. Trigger: Author clicks "Run Reviewer" or status changes to a trigger_status
2. Enqueue: AutomatedReviewJob.perform_later(plan_id:, reviewer_id:, triggered_by:)
3. Job executes:
   a. Load plan + current version content
   b. Load prompt from file: File.read(Rails.root.join(reviewer.prompt_path))
   c. Compose messages: system prompt + plan content
   d. Call AI provider (ruby-openai)
   e. Create CommentThread (general, no line range) + Comment with response
   f. Create Notification for plan author
   g. Post to Slack webhook if configured
4. Turbo Streams broadcast the new thread/comment to all viewers
```

---

## Markdown Rendering

Two views of a plan document:

1. **Rendered view** — `commonmarker` HTML output, sanitized, for reading
2. **Line view** — raw markdown lines, each wrapped in `<div id="L{n}" data-line="{n}">`, for commenting

Comments are made on the **line view**. A Stimulus controller handles line-range selection and opens a comment composer.

---

## Phased Build Order

### Phase 0 — Rails Skeleton

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 0.1 | New Rails 8 app | `rails new` with importmaps, Turbo, Stimulus, PostgreSQL, SolidQueue, SolidCable. Configure UUID primary key defaults. Install ActiveAdmin 4 beta + `activeadmin_assets` (no node/tailwind needed). | App boots, `rails db:create` works, `/admin` loads |
| 0.2 | Layout + CSS foundation | Application layout, basic navigation structure, CSS reset + design tokens (colors, spacing, typography). Error pages. | Styled app shell |

### Phase 1 — Orgs + Auth

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 1.1 | Organization + User models | Migrations, models, validations, seeds. `Current.organization` / `Current.user` setup. Domain matching on user creation. | Models pass unit tests |
| 1.2 | Authentication | Stub OIDC login: enter email → domain checked → session created. No passwords, no Devise, no OmniAuth. `SessionsController` with cookie-based sessions. | Can sign in and see a dashboard |
| 1.3 | Authorization helpers | Simple policy objects (not Pundit — keep it minimal). `authorize!` helper for controllers. Org-scoped `ApplicationController` base. | Org isolation enforced |

### Phase 2 — Plans + Versions

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 2.1 | Plan + PlanVersion models | Migrations, models, associations. Service object: `Plans::Create.call(title:, content:, user:)` creates plan + version 1. | Models + service pass tests |
| 2.2 | Plans CRUD UI | Index page (org-scoped, filtered by status). New plan form (title + paste/upload markdown). Show page with current content. Status badge. | Can create and view plans in browser |
| 2.3 | Version history | Version list sidebar/section on plan show page. Click to view any version. Diff view between adjacent versions using `diffy`. | Can browse full version history |
| 2.4 | Status transitions + visibility | Status update controls (Author only). Enforce brainstorm privacy — 404 for non-collaborators. Collaborator model + invite flow. | Status workflow works, privacy enforced |

### Phase 3 — Markdown Rendering + Line View

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 3.1 | Rendered markdown view | `commonmarker` pipeline with HTML sanitization. Rendered view as default on plan show page. | Plans render as formatted HTML |
| 3.2 | Line-numbered view | Raw markdown as numbered `<div>` elements. Toggle between "Rendered" and "Lines" view (Turbo Frame). | Can switch views, lines are addressable |
| 3.3 | Line selection UX | Stimulus controller: click a line to select it, shift-click to select a range, selection highlights, "Add comment" button appears. | Can select line ranges for commenting |

### Phase 4 — Commenting

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 4.1 | CommentThread + Comment models | Migrations, models, associations. Scoped to plan + version. | Models pass tests |
| 4.2 | Comment UI — create + display | Comment threads displayed in a sidebar/panel next to the line view. Create thread form (from line selection). Reply to thread. | Can comment on lines and reply |
| 4.3 | Thread lifecycle | Resolve / accept / dismiss controls (Author only for accept). Mark threads out-of-date on new version. "Out of date" badge with link to original version. | Full comment lifecycle works |

### Phase 5 — Turbo Streams (Realtime)

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 5.1 | Comment broadcasting | New comments + thread status changes broadcast via Turbo Streams. Multiple browser tabs see updates instantly. | Realtime comments |
| 5.2 | Version + status broadcasting | New version creation replaces content + prepends to version list. Status changes update header. Out-of-date badges update. | Full realtime plan page |

### Phase 6 — API + Edit Leases + Operations

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 6.1 | API token model + management | ApiToken model. UI: create token (show raw once), list tokens, revoke. | Users can create API tokens |
| 6.2 | API authentication + read endpoints | `Api::V1::BaseController` with token auth. `GET /api/v1/plans/:id`, `GET /api/v1/plans/:id/versions`, `GET /api/v1/plans/:id/comments`. | Agents can read plans via API |
| 6.3 | Edit lease endpoints | `POST /api/v1/plans/:id/lease` (acquire), `PATCH /api/v1/plans/:id/lease` (renew), `DELETE /api/v1/plans/:id/lease` (release). Atomic UPSERT with TTL. | Agents can acquire/release edit locks |
| 6.4 | Operations engine | `Plans::ApplyOperations` service. Unit tests for `replace_exact`, `insert_under_heading`, `delete_paragraph_containing`. Error cases (not found, ambiguous). | Operations engine passes tests |
| 6.5 | Operations API endpoint | `POST /api/v1/plans/:id/operations`. Validates lease, validates base_revision, applies ops, creates version, broadcasts. 409 on stale revision. | Agents can edit plans via API |
| 6.6 | Comment API endpoints | `POST /api/v1/plans/:id/comments` (create thread + comment), `POST /api/v1/plans/:id/comments/:thread_id/replies`. | Agents can comment via API |

### Phase 7 — Cloud Personas

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 7.1 | AutomatedPlanReviewer model + prompts | Model + migration. Seed data from prompt files in `prompts/reviewers/`. Admin list view. | Persona records exist, prompts load from disk |
| 7.2 | AI provider service | `AiProviders::OpenAi` service wrapping `ruby-openai`. Accepts messages, returns response. Logs prompt/response. | Can call OpenAI and get a response |
| 7.3 | AutomatedReviewJob | SolidQueue job: loads plan + prompt, calls AI, creates CommentThread + Comment as `cloud_persona` actor. | Running a persona creates a review comment |
| 7.4 | Persona trigger UI + auto-trigger | "Run Reviewer" button on plan page. Auto-trigger on status → considering (configurable per persona via `trigger_statuses`). | Personas run on demand or automatically |

### Phase 8 — Notifications

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 8.1 | Notification model + creation | Model + migration. Create notifications on: comment created, thread resolved/accepted, status changed, persona completed. | Notifications created on key events |
| 8.2 | In-app notification UI | Notification bell in nav with unread count. Dropdown/page listing notifications. Mark as read. | Users see notifications in-app |
| 8.3 | Slack webhook notifications | `SlackNotifier` service using `Net::HTTP`. Posts to org's `slack_webhook_url` on same events. | Notifications appear in Slack |

### Phase 9 — Hardening

| # | Session | What Gets Built | Deliverable |
|---|---------|-----------------|-------------|
| 9.1 | Real OIDC authentication | Replace stub login with hand-rolled OIDC client (~50 lines, no gem). HTTP calls to provider token + userinfo endpoints. Configurable per org. Stub still works for dev. | SSO login works with real providers |
| 9.2 | Rate limiting + security | `rack-attack` for API endpoints. Request logging. CSRF hardening. Content Security Policy. | API is rate-limited, security headers set |
| 9.3 | Auto-archive job | Scheduled SolidQueue job: plans in `brainstorm` with no activity for N days → `abandoned`. Configurable threshold. | Stale plans auto-archive |
| 9.4 | "Ask an Agent" feature | Text input on plan page → sends question + plan content to AI provider → displays answer with line citations in a panel. | Users can ask questions about a plan |

---

## Session Dependency Graph

```
Phase 0 (skeleton)
  └→ Phase 1 (auth)
       └→ Phase 2 (plans + versions)
            ├→ Phase 3 (markdown + line view)
            │    └→ Phase 4 (commenting)
            │         └→ Phase 5 (turbo streams)
            └→ Phase 6 (API + operations)
                 └→ Phase 7 (cloud personas)
                      └→ Phase 8 (notifications)
                           └→ Phase 9 (hardening)
```

Phases 3-5 (web UX) and Phase 6 (API) can be built in parallel after Phase 2 if desired.

---

## What Each Session Should Produce

Every session should end with:

1. **Working code** — migrations run, app boots, no errors
2. **Tests** — model validations, service objects, and controller actions tested
3. **Seed data** — updated `db/seeds.rb` so a fresh checkout can demo the feature
4. **ActiveAdmin registration** — if new models were added, register them in ActiveAdmin so they're browsable/editable at `/admin`
5. **Styles and UI** — any new views should be styled and usable, not left as unstyled scaffolds
6. **Code review** — run the `code-review` skill, address all feedback until clean. Session is not complete until the review passes.
7. **No loose ends** — if something is stubbed, note it in a TODO comment with the session that will implement it

---

## File Structure (Expected)

```
app/
  controllers/
    application_controller.rb
    plans_controller.rb
    plan_versions_controller.rb
    comment_threads_controller.rb
    comments_controller.rb
    api/
      v1/
        base_controller.rb
        plans_controller.rb
        operations_controller.rb
        comments_controller.rb
        leases_controller.rb
  models/
    organization.rb
    user.rb
    plan.rb
    plan_version.rb
    comment_thread.rb
    comment.rb
    plan_collaborator.rb
    api_token.rb
    edit_lease.rb
    automated_plan_reviewer.rb
    notification.rb
  services/
    plans/
      create.rb
      apply_operations.rb
    ai_providers/
      open_ai.rb
    slack_notifier.rb
  jobs/
    automated_review_job.rb
    auto_archive_plans_job.rb
  views/
    plans/
    plan_versions/
    comment_threads/
    comments/
    notifications/
    admin/        (ActiveAdmin view overrides if needed)
  admin/
    organizations.rb
    users.rb
    plans.rb
    plan_versions.rb
    comment_threads.rb
    api_tokens.rb
    automated_plan_reviewers.rb
    edit_leases.rb
    notifications.rb
prompts/
  reviewers/
    security.md
    scalability.md
    routing.md
```
