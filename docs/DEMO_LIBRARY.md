# Shared demo library

CoPlan ships one reusable development dataset in the engine gem. Use it for
feature work, browser checks, screenshots, and demos. The content is readable
Markdown in `engine/db/demo/content/`; scenario definitions and relationships
live in `engine/lib/coplan/development_seed.rb`.

## Start here

In this repository's example host:

```sh
bin/setup --skip-server
bin/dev
```

Open `http://localhost:3000/sign_in` and sign in as **hampton@example.com**.
The field is prefilled after seeding. The login page also lists all seeded
demo accounts; select an account button to sign in directly. Open
`http://localhost:3000/hampton/demo-library` for links to every example.
There is no password in the example host's development login.

| Login | Identity | Useful for |
| --- | --- | --- |
| hampton@example.com | Hampton | Default owner and admin; decks, collaboration, review scenarios |
| alex@example.com | Alex Morgan | Admin and architecture approver |
| noura@example.com | Noura Haddad | Security approver and Arabic content |
| sam@example.com | Sam Chen | Code, tables, slide patterns, readable URL examples |
| mateo@example.com | Mateo García | Mobile checkout and Spanish content |
| aiko@example.com | Aiko Tanaka | Reliability, runbook, Japanese content |

Gem hosts can run `bin/rails coplan:demo:seed` without copying host seed files
or installing Faker. Authentication belongs to the host: map your development
login to the seeded external identity (for example, `seed:hampton`).
`bin/rails coplan:seed` installs required reference data only; it does not
install demo users or documents.

## Named scenarios

The index starts with **Diagrams**, **Presentations**, **Tables and rich text**,
and **References**. Every link labels the document's actual plan type. The
**Every plan type** section links to a real example of each of the twelve
shipped types, including Scratchpad, PRD, Test Plan, and Handoff.

| Content example | What to try |
| --- | --- |
| writing-legacy-unknown | Pre-identity history repaired as Unknown; recorded agent identities are preserved |
| diagram-comments | Flowchart node and edge discussions; browse, press C, select an element, expand |
| entity-relationships / class-model | ER and class diagrams with whole-diagram discussions |
| mobile-checkout / long-title | State and sequence diagrams with whole-diagram discussions |
| single-slide | One slide with speaker notes |
| launch-deck | A complete multi-slide presentation |
| mixed-slides | Prose around two separately presentable decks; diagrams, code, table, image, notes |
| pattern-showcase | Title, columns, stage, quote, code, image, and table slide layouts |
| reference-gallery | All five reference types, a resolved CoPlan target, explicit/extracted references, named citations, repeated URLs, footnotes |
| table-gallery | Precise cell discussion, repeated labels, empty values, links, wide expandable data |
| formatting-gallery | Headings, editable template notes hidden while reading, emphasis, quotes, nested lists, tasks, two code languages, image, mention, footnote |
| reading-specimen | A realistic design doc for judging reading in both modes: prose, headings, lists, tasks, quote, table, footnote, image, SQL/Ruby/diff/YAML code, a long scrolling line, flowchart and sequence diagrams, plus open, agent-answered, resolved, diagram-node, table-cell, and general discussions |
| image-resizing | Resize and restore image widths, wrap prose from the top, Shift+Enter beside, Enter below |

Flowcharts currently support source-backed node and edge comments. Other
Mermaid types support whole-diagram comments. The demos label this boundary;
they do not imply entity, class, state, or sequence-message anchoring.

Review-state examples remain available near the end of the index. They are
independent fixtures for feature work, rather than the entry point to the
content library.

The demo image is packaged in the engine assets. `{{demo_logo_url}}` in a
fixture resolves through the host's asset helper. Untouched older image
examples upgrade from the example-host image URL; edited content is preserved.

Demo fixture attribution is simulated; re-seeding preserves subsequent human edits.
Inspect prose, code, and slide text; diagrams and images retain their rendering.

Each plan has `metadata["development_seed_key"]`. Specs and scripts should
look up this key rather than copying generated UUIDs.

| Key | Expected initial state |
| --- | --- |
| untouched-document | One version, no comments or collaborators |
| many-small-edits | Eight versions: initial draft plus seven small agent edits with token provenance |
| writing-human / writing-ai / writing-unknown | Person, robot, and unknown icons; lazy source breakdown and reported harness identity |
| writing-mixed | Human input, unknown imported context, and an agent proposal; opt-in source inspection |
| writing-word-edit | Agent text with a human-added “not” in v2; hover for Hampton, version, and time |
| pending-review | Two approvers, neither approved |
| approved-review | Two approvers, both approved |
| collab-showcase | Agent edit, human and agent comments, open/resolved and overlapping anchors, general thread, citations and references |
| api-gateway | Architecture proposal with a wide flowchart, trust-boundary table, rollout, external links |
| launch-deck | Presentation with speaker notes |
| pattern-showcase | Presentation layout examples, including deliberate overflow |
| experiment-results | Wide research table with cohort comparisons |
| code-walkthrough | Dense code, inline discussion, and related-reading target |
| long-mobile-toc | More than 30 meaningful sections for navigation checks |
| draft-notes | Unlisted author draft; its original title URL redirects after a retitle |
| archived-proposal | Archived document available through a direct link |
| spanish-brief / japanese-roadmap / arabic-research | Multilingual and right-to-left content |
| liveorder-* / pricing-rules | Folder rename, document retitle, aliases, slug collision |
| agent-pick-* | Agent-attributed grouped library organization |

Approval states are real `PlanCollaborator` approvers with or without
`approved_at`. They are separate from discussion resolution and unread
notification state. The untouched and approved documents have no pending
discussions.

## Missing pages

The **missing-page** scenario links to `/_/not-found` from the demo index.
Choose the puzzle-piece icon below the glass panel to open the game. The page returns HTTP 404
and keeps navigation in the regular header, with a
keyboard- and touch-accessible path puzzle. Rotate tiles to connect IN to OUT;
Start over restores the initial board. It needs no seeded records of its own.

## Agent access

The named `agent-access` scenario is linked from the demo index to Settings.
Sign in as Hampton to inspect a work laptop personal token, child and
host-authenticated sessions, missing identity fields, and 28 past sessions
for pagination. Re-seeding preserves revocations and expiry dates.

The `agent-connection` scenario previews pending, expired, and declined browser
approval requests on hosts without implicit API authentication. Their private
redemption secrets are discarded, so previews cannot issue credentials. Start
the helper from Agent setup for a real connection. Re-seeding preserves the
decision and expiry of each preview.

## Re-seeding and isolation

```sh
bin/rails coplan:demo:seed
```

Re-seeding adds missing documents and keeps existing content, titles, approval
decisions, and discussion state. It refreshes seed-owned user profiles, tags,
types, and folder placements. It does not restore initial review states after
you try them. Use a fresh development database for a pristine demo; do not
reset a shared database or erase someone's feature work.

The earlier `seed:priya` default identity upgrades to `seed:hampton` in place.
Its user ID, documents, comments, and attribution stay intact. A `priya`
library handle becomes `hampton`, with an alias preserving its old links.

Different worktrees need different database names. A different server port
alone does not isolate data: this host defaults to `coplan_development` in
every checkout. Set `DATABASE_URL` to a dedicated local database for both
setup and the server. Keep test databases separate as well.

### Parallel local agents

Give each agent or worktree a unique name (replace `agent_a` below) and an
unused port. In that checkout, keep these variables in the shell used to
set up, seed, and start the server:

```sh
export DATABASE_URL='mysql2://root@localhost/coplan_agent_a_development?socket=/tmp/mysql.sock'
export COPLAN_DEMO_BASE_URL='http://localhost:3100'
bin/setup --skip-server
bin/rails coplan:demo:seed
bin/dev -p 3100
```

Open `http://localhost:3100/hampton/demo-library` after signing in as
`hampton@example.com`. A second agent might use `coplan_agent_b_development`
and port `3101`. Adjust credentials and the socket for your local MySQL setup.
Do not replace another agent's running server.

Run specs against a different database in a separate shell or with an inline
override. Prepare a **new, dedicated** test database once:

```sh
DATABASE_URL='mysql2://root@localhost/coplan_agent_a_test?socket=/tmp/mysql.sock' \
  RAILS_ENV=test bin/rails db:create db:schema:load
DATABASE_URL='mysql2://root@localhost/coplan_agent_a_test?socket=/tmp/mysql.sock' \
  bundle exec rspec
```

Never point these test commands at a development database: specs clear data.
Do not seed the test database manually; specs create their own fixtures.
Keep using the same development URL for subsequent seed commands. Re-seed
to add new examples, or select a new database name for pristine scenarios;
do not use `bin/setup --reset` on a database shared with another chat.

For another port or an engine mounted at `/coplan`, set the base URL before
the first seed:

```sh
COPLAN_DEMO_BASE_URL=http://localhost:3100/coplan bin/rails coplan:demo:seed
```

The base URL is written into example links. Existing document content is
preserved on later runs, so keep that address for the demo or use a fresh
database when changing it. The seed refuses to run outside development and
test, including when invoked directly from Ruby.

## Add an example

When a feature adds a content type, diagram variant, reference type,
presentation layout, or other demoable content or workflow state, add or
update a named example in the same PR. The feature is complete when someone
can open that example from the demo index and try the new behavior.

1. Add a Markdown file in `engine/db/demo/content/`.
2. Add a definition with a stable key to `DevelopmentSeed::DOCUMENTS`.
3. Seed the real relationships or versions needed by the feature.
4. Add assertions for the initial state, repeatability, and preservation of
   local changes in `spec/lib/development_seed_spec.rb`.
5. Run the seed and relevant specs, then try the example in both modes.

The browsable index includes every definition and refreshes as examples are
added. If you edit the index yourself, re-seeding preserves your version.
The spec verifies every current definition has a working index link.
