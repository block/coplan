require "faker"

module CoPlan
  # A deterministic, idempotent dataset for exercising CoPlan's development UI.
  # Existing seed documents keep local content edits; missing records are restored
  # on the next run and seed-owned metadata remains consistent.
  module DevelopmentSeed
    module_function

    USERS = [
      { key: "alex", locale: :en, admin: true },
      { key: "priya", locale: :en },
      { key: "mateo", locale: :es },
      { key: "aiko", locale: :ja },
      { key: "noura", locale: :ar },
      { key: "sam", locale: :en }
    ].freeze

    PLAN_TYPES = [
      { name: "General", icon: "file-text", description: "A flexible document for notes and proposals", default_tags: [] },
      { name: "RFC", icon: "scroll", description: "A request for comments on a significant change", default_tags: [ "rfc" ] },
      { name: "Design Doc", icon: "compass", description: "Technical design for a system or feature", default_tags: [ "design" ] },
      { name: "ADR", icon: "scale", description: "A durable architecture decision record", default_tags: [ "architecture" ] },
      { name: "Product Brief", icon: "lightbulb", description: "Product context, goals, and measures of success", default_tags: [ "product" ] },
      { name: "Runbook", icon: "wrench", description: "Operational diagnosis and recovery steps", default_tags: [ "operations" ] },
      { name: "Research Note", icon: "flask", description: "Findings, evidence, and open questions", default_tags: [ "research" ] },
      { name: "Roadmap", icon: "map", description: "Sequenced outcomes and milestones", default_tags: [ "roadmap" ] },
      { name: "Presentation", icon: "presentation", behavior: "presentation", description: "A markdown slide deck — `---` starts a new slide", default_tags: [] }
    ].freeze

    # The browsable-URL showcase renames one folder and retitles one
    # document, so a freshly seeded app has real aliases to follow at the root.
    # Both steps are guarded on these values and no-op on re-seed.
    RENAMED_FOLDER_FROM = "Order platform".freeze
    RENAMED_FOLDER_TO = "LiveOrder".freeze
    RETITLED_DOCUMENT_FROM = "LiveOrder pricing rules v1".freeze
    RETITLED_DOCUMENT_TO = "LiveOrder pricing rules".freeze

    # Left unfiled by DOCUMENTS so the agent organize run below has real
    # work to do. See seed_agent_organization_run.
    AGENT_ORGANIZED_KEYS = %w[agent-pick-metrics agent-pick-postmortem agent-pick-vendors].freeze

    DOCUMENTS = [
      {
        key: "one-line-decision", author: "alex", type: "ADR", title: "Use UUIDv7 identifiers",
        tags: %w[architecture database], visibility: "published", folder: "Engineering/Architecture decisions", sections: 0
      },
      {
        key: "api-gateway", author: "alex", type: "RFC", title: "RFC: Consolidating edge authentication in the API gateway",
        tags: %w[api security infrastructure], visibility: "published", folder: "Engineering/Active projects", fixture: :flowchart
      },
      {
        key: "mobile-checkout", author: "mateo", type: "Design Doc", title: "Mobile checkout: resilient state transitions when the network disappears",
        tags: %w[mobile reliability payments], visibility: "published", folder: "Product/Mobile", fixture: :state_diagram
      },
      {
        key: "spanish-brief", author: "mateo", type: "Product Brief", title: "Mejoras para la experiencia de incorporación",
        tags: %w[onboarding product localization], visibility: "published", folder: "Product/Discovery", fixture: :spanish
      },
      {
        key: "japanese-roadmap", author: "aiko", type: "Roadmap", title: "信頼性向上ロードマップ — 2027年前半",
        tags: %w[reliability roadmap], visibility: "published", folder: "Operations/Reliability", fixture: :japanese
      },
      {
        key: "arabic-research", author: "noura", type: "Research Note", title: "بحث: تقليل مخاطر سرقة الجلسات",
        tags: %w[security research authentication], visibility: "published", folder: "Research/Security", fixture: :arabic
      },
      {
        key: "incident-runbook", author: "aiko", type: "Runbook", title: "Payments API latency incident runbook",
        tags: %w[operations payments on-call], visibility: "published", folder: "Operations/Runbooks"
      },
      {
        key: "experiment-results", author: "sam", type: "Research Note", title: "Search ranking experiment #42",
        tags: %w[search experimentation data], visibility: "published", folder: "Research/Experiments", fixture: :table
      },
      {
        key: "draft-notes", author: "priya", type: "General", title: "Untitled thoughts on activation",
        tags: %w[product draft], visibility: "draft", folder: "Personal notes", sections: 1
      },
      {
        key: "archived-proposal", author: "alex", type: "RFC", title: "Retired proposal: weekly XML exports",
        tags: %w[archive integrations], visibility: "published", archived: true, folder: "Engineering/Archive", sections: 1
      },
      {
        key: "emoji-title", author: "priya", type: "Product Brief", title: "Faster feedback loops ⚡",
        tags: %w[collaboration product], visibility: "published", folder: "Product/Discovery"
      },
      {
        key: "long-title", author: "noura", type: "Design Doc",
        title: "Designing a privacy-preserving audit trail for delegated administrative actions across regional data boundaries",
        tags: %w[security privacy compliance], visibility: "published", folder: "Engineering/Architecture decisions", fixture: :sequence_diagram
      },
      {
        key: "long-mobile-toc", author: "priya", type: "Product Brief", title: "The complete guide to launching shared workspaces across web, iOS, and Android",
        tags: %w[collaboration mobile launch], visibility: "published", folder: "Product/Launches/Shared workspace", long: true
      },
      {
        key: "code-walkthrough", author: "sam", type: "Design Doc", title: "Order discount engine: implementation walkthrough",
        tags: %w[pricing api design], visibility: "published", folder: "Engineering/Active projects", fixture: :code_walkthrough
      },
      {
        key: "collab-showcase", author: "priya", type: "Design Doc", title: "Search latency: cutting p95 with a two-tier cache",
        tags: %w[search performance caching], visibility: "published", folder: "Engineering/Active projects", fixture: :collab_showcase
      },
      {
        key: "launch-deck", author: "priya", type: "Presentation", title: "Shared workspaces launch — readout deck",
        tags: %w[collaboration launch], visibility: "published", folder: "Product/Launches/Shared workspace", fixture: :slideshow_deck
      },
      {
        key: "pattern-showcase", author: "sam", type: "Presentation", title: "Slide layout patterns — a tour of the deck design system",
        tags: %w[design slides], visibility: "published", folder: "Engineering/Active projects", fixture: :pattern_showcase
      },
      # A folder whose documents all repeat its name — the shape that makes
      # a real library unreadable, and exactly what URL slugs strip. These
      # land at /<handle>/liveorder/{cart-state-machine,…}, with
      # "LiveOrder" appearing once, in the folder segment where it belongs.
      {
        key: "liveorder-cart", author: "sam", type: "Design Doc", title: "LiveOrder cart state machine",
        tags: %w[orders design], visibility: "published", folder: RENAMED_FOLDER_TO
      },
      {
        key: "liveorder-webhooks", author: "sam", type: "Design Doc", title: "LiveOrder fulfillment webhooks",
        tags: %w[orders api], visibility: "published", folder: RENAMED_FOLDER_TO
      },
      # Collides with liveorder-pricing once that one is retitled: both
      # strip to `pricing-rules`, so one picks up a ~suffix.
      {
        key: "pricing-rules", author: "sam", type: "General", title: "Pricing rules",
        tags: %w[orders pricing], visibility: "published", folder: RENAMED_FOLDER_TO
      },
      {
        key: "liveorder-pricing", author: "sam", type: "General", title: RETITLED_DOCUMENT_FROM,
        tags: %w[orders pricing], visibility: "published", folder: RENAMED_FOLDER_TO
      },
      # No `folder:` — these sit loose at the root of Alex's library until
      # the agent organize run files them (AGENT_ORGANIZED_KEYS). Root-level
      # documents are also what /<handle> shows with no folder segment.
      {
        key: "agent-pick-metrics", author: "alex", type: "Research Note", title: "Activation metrics worth arguing about",
        tags: %w[product data], visibility: "published", sections: 1
      },
      {
        key: "agent-pick-postmortem", author: "alex", type: "Runbook", title: "Postmortem: the Tuesday cache stampede",
        tags: %w[operations reliability], visibility: "published", sections: 1
      },
      {
        key: "agent-pick-vendors", author: "alex", type: "General", title: "Vendor evaluation notes",
        tags: %w[procurement], visibility: "published", sections: 1
      }
    ].freeze

    # Identity the collaboration fixtures attribute agent activity to —
    # renders as "Claude (via <user>)" in history, comments, and audit events.
    AGENT_NAME = "Claude"
    AGENT_TOKEN_NAME = "Claude Code (development seed)"
    AGENT_ORGANIZE_RUN_ID = "development-seed-organize-run"

    CONTENT_FIXTURES = {
      flowchart: <<~MARKDOWN,
        ```mermaid
        flowchart LR
          Client --> Gateway
          Gateway --> API
          API --> DB[(Database)]
        ```
      MARKDOWN
      state_diagram: <<~MARKDOWN,
        ```mermaid
        stateDiagram-v2
          [*] --> Editing
          Editing --> Submitting
          Submitting --> Confirmed
          Confirmed --> [*]
        ```
      MARKDOWN
      sequence_diagram: <<~MARKDOWN,
        ```mermaid
        sequenceDiagram
          participant A as Administrator
          participant S as Service
          A->>S: Delegated action
          S-->>A: Receipt ID
        ```
      MARKDOWN
      table: <<~MARKDOWN,
        | Metric | Control | Treatment |
        | --- | ---: | ---: |
        | Success | 61.2% | 62.9% |
        | Errors | 18.4% | 17.7% |
      MARKDOWN
      code_walkthrough: <<~'MARKDOWN',
        How the discount engine decides what every line item costs. Each stage is
        shown in the language it ships in — service code, client hook, schema,
        rollout commands — so this doc doubles as a demo of syntax highlighting.

        ## Where discounts happen

        ```mermaid
        flowchart LR
          POS[POS client] --> API
          API --> Engine[Discount engine]
          Engine --> Rules[(Rule store)]
          Engine --> Ledger[(Price ledger)]
        ```

        ## The engine core

        The engine walks each cart once, folding applicable rules into a final
        per-line price. Rules never see the running total — that keeps them pure
        and independently testable.

        ```ruby
        # Applies every eligible rule to a cart, cheapest-first.
        class DiscountEngine
          MAX_STACK = 3

          def initialize(rules:, clock: Time)
            @rules = rules.sort_by(&:priority)
            @clock = clock
          end

          def price(cart)
            cart.line_items.map do |item|
              applied = @rules
                .select { |rule| rule.eligible?(item, at: @clock.now) }
                .first(MAX_STACK)

              total = applied.reduce(item.amount) { |amount, rule| rule.apply(amount) }
              PricedItem.new(item:, total:, applied_rules: applied.map(&:code))
            end
          end
        end
        ```

        ## Client hook

        The POS reads priced carts through a small hook — no pricing logic
        client-side, ever.

        ```typescript
        interface PricedItem {
          name: string;
          total: number;
          appliedRules: string[];
        }

        export function usePricedCart(cartId: string): PricedItem[] {
          const { data, error } = useSWR<PricedItem[]>(`/api/carts/${cartId}/pricing`);
          if (error) throw new PricingUnavailableError(cartId);
          return data ?? [];
        }
        ```

        ## Rule storage

        ```sql
        CREATE TABLE discount_rules (
          id CHAR(36) PRIMARY KEY,
          code VARCHAR(64) NOT NULL UNIQUE,
          priority INT NOT NULL DEFAULT 100,
          percent_off DECIMAL(5, 2) NOT NULL,
          starts_at DATETIME NOT NULL,
          ends_at DATETIME
        );

        -- Most queries are "which rules are live right now?"
        CREATE INDEX idx_rules_window ON discount_rules (starts_at, ends_at);
        ```

        ## Rollout

        Ship dark, then ramp by merchant cohort:

        ```bash
        bin/rails discounts:backfill_rules DRY_RUN=1
        bin/rails discounts:backfill_rules
        curl -sf "$API/flags/discount-engine" -d 'cohort=1' | jq .rollout
        ```

        The flag change that turned it on for the pilot cohort:

        ```diff
         flags:
           discount-engine:
        -    enabled: false
        +    enabled: true
        +    cohorts: [pilot-merchants]
        ```

        ## Ledger spot-check

        Raw output pasted straight from the console — no language tag, so no
        header and no highlighting:

        ```
        cart 8842 → "espresso"   base 450  applied [SUMMER10, LOYALTY5]  total 384
        cart 8842 → "croissant"  base 375  applied []                    total 375
        cart 8842 → "cold brew"  base 525  applied [SUMMER10]            total 472
        ```

        As the payments team put it during review:

        > Pricing bugs are the only bugs customers find before your tests do.
        > Fold the ledger check into CI before cohort 3, not after.

        ## Open questions

        - Should `MAX_STACK` be a merchant setting instead of a constant?
        - The ledger write is synchronous — acceptable at pilot volume, but see
          the latency budget before cohort 3.
      MARKDOWN
      # Exercises the reference system end-to-end: footnote citations with
      # source links (auto-extracted into References), explicit numbered
      # section links (hover previews), and prose worth commenting on —
      # the comment/attribution fixtures below anchor to sentences here.
      collab_showcase: <<~'MARKDOWN',
        Search p95 sits at 840 ms while p50 is fine — the tail is repeat fan-out, not slow ranking.[^p95-baseline] This design layers a request-local memo over a shared Redis tier to pull p95 under 300 ms without serving stale facets, and writes down the invalidation rules reviewers keep asking about (see [§3](#section-3)).

        ## 1. Problem

        Every keystroke fans out to the ranking service, and most of that work repeats: two people typing "refund policy" build the same candidate set twice. The ranking call dominates the tail — [§4](#section-4) covers how the rollout measures it.

        ## 2. Two tiers, one interface

        A request-local memo catches repeats within one search session; the shared Redis tier catches repeats across users. Eviction on the shared tier follows an allkeys-lru policy.[^redis-eviction]

        ```ruby
        class CacheStack
          def initialize(local:, shared:)
            @tiers = [ local, shared ]
          end

          def fetch(key, &compute)
            @tiers.each_with_index do |tier, index|
              value = tier.read(key)
              next unless value
              promote(key, value, upto: index)
              return value
            end
            compute.call.tap { |value| write_through(key, value) }
          end
        end
        ```

        ## 3. Invalidation

        Facet counts may lag content by at most one minute. Writes publish a version stamp; a cached entry older than the stamp for any document in its candidate set is treated as a miss. There is no per-key TTL tuning — the stamp is the whole strategy.

        ## 4. Rollout

        Dark-read first: serve uncached results while comparing them with cached results in the background, then ramp by query class once the comparison disagrees on fewer than 1 in 10,000 queries — the bar the invalidation rules in [§3](#section-3) were written to clear.

        [^p95-baseline]: [Q2 search latency review](https://observability.example.com/d/search-latency) — trailing 30 days: p95 840 ms, p50 118 ms, with fan-out retries accounting for 62% of tail samples.
        [^redis-eviction]: [Redis key eviction](https://redis.io/docs/latest/develop/reference/eviction/) — `allkeys-lru` approximates LRU across the whole keyspace, which fits a cache-only tier.
      MARKDOWN
      # Showcases the slideshow conventions end-to-end: `---` slide breaks,
      # speaker-note comments, a visible `***` rule (not a break), checkboxes
      # on a later slide (absolute line numbers), and footnote/link-reference
      # definitions that live on a different slide than their references.
      slideshow_deck: <<~'MARKDOWN',
        Q3 launch readout, presented at the product review. A `---` on its own line starts a new slide.

        <!-- notes: Open with the one-number summary — adoption doubled. -->

        ---

        ## What shipped

        - Shared workspaces on web, iOS, and Android
        - Folder-level permissions with inherited defaults
        - Real-time presence in every document[^presence]

        ***

        Rules like the one above stay visible — only `---` starts a new slide.

        ---

        ## Rollout checklist

        - [x] Beta cohort (12 teams)
        - [x] Pricing page update
        - [ ] Follow-up survey to beta admins

        <!-- notes: The survey ships Friday; results feed the next readout. -->

        ---

        ## How it went

        ```text
        week 1  ████████ 41%
        week 2  ██████████████ 72%
        week 4  ████████████████ 89%
        ```

        Weekly active teams, per the [launch dashboard][dash].

        ---

        ## Ask

        Approve headcount for the sync-conflicts workstream.

        [dash]: https://observability.example.com/d/workspace-adoption
        [^presence]: Presence reuses the comment-notification channel, so it ships with no new infrastructure.
      MARKDOWN
      # One slide per layout pattern in docs/SLIDE_SPEC.md, in catalog
      # order — the visual regression corpus for the deck design system.
      # Layout is inferred from content shape; nothing here is a directive.
      pattern_showcase: <<~'MARKDOWN',
        Every slide in this deck earns its layout from its shape alone.

        ---

        ## What the classifier sees

        - A lone heading becomes a title slide
        - Two lists sit side by side
        - One image or diagram takes the whole stage
        - Code gets the stage, not a text box

        ---

        ## Writing a deck / designing a deck

        - pick the words
        - split with `---`
        - share the plan link

        * no theme CSS
        * no layout directives
        * no ugly slides

        ---

        ## The decision list

        ```ruby
        return :title if lead && body.empty?
        return :stage if media_block?(featured)
        return :split if media_at_edge?(body)
        ```

        ---

        ## How a slide finds its shape

        ```mermaid
        flowchart LR
          MD[markdown] --> Split --> Classify
          Classify --> T[title]
          Classify --> C[columns]
          Classify --> S[stage]
        ```

        ---

        ## Reviewed like a document

        - Comment on any bullet, on any slide
        - Every edit is a version with provenance
        - Present from the same link

        ![CoPlan](/coplan-logo.png)

        <!-- notes: This split slide is why decks live in CoPlan at all. -->

        ---

        > The default output has to be genuinely beautiful with zero effort.

        — the design plan

        ---

        ## Type steps, not shrink-to-fit

        | Units | Step | Feels like |
        |---|---|---|
        | ≤ 5 | 1 | a poster |
        | 6–9 | 2 | a slide |
        | 10–14 | 3 | a dense slide |
        | 15+ | 4 | time to split it |

        ---

        ## A dense slide steps down

        - the type scale drops one discrete step at a time
        - so sparse slides look intentional, not zoomed in
        - and dense slides fit without shrink-to-fit soup
        - seven or more lines lands on step two
        - past fourteen you get step four, the floor
        - past the floor, content scrolls instead of clipping
        - and the fit report will tell the agent to split the slide
        - which is the honest fix anyway
        - one idea per slide beats one slide per idea

        ---

        ## When a slide is mostly words

        Some slides are paragraphs, not bullets — the narrative beat in the middle of a readout, the decision memo an exec will actually read, the part you'd deliver word for word. The classifier doesn't blink: prose is billed line for line, the type scale steps down, and the slide stays a slide.

        Nothing past the smallest step gets clipped. The card scrolls, and the fit report will tell the author — human or agent — exactly which slide burst its budget and by how much, so too much text becomes an editing decision instead of a rendering accident.

        Steps are discrete on purpose. Sparse slides look intentional at full size instead of zoomed in, dense slides stay readable at the floor, and nothing wobbles between the two while you type.

        ---

        ## Every project in flight

        - **Atlas** — payment routing rewrite
        - **Beacon** — merchant onboarding funnel
        - **Cairn** — ledger archival tier
        - **Delta** — settlement diff tooling
        - **Ember** — incident review workflow
        - **Fathom** — search relevance overhaul
        - **Garnet** — receipts rendering service
        - **Harbor** — sandbox environment refresh
        - **Ivory** — design token consolidation
        - **Juniper** — notification digest engine
        - **Keel** — schema migration guardrails
        - **Lumen** — dashboard latency budget
        - **Mesa** — reporting warehouse sync
        - **Nimbus** — mobile offline cache
        - **Onyx** — audit log retention
        - **Prism** — experiment analysis pipeline
        - **Quarry** — data extraction contracts
        - **Rudder** — feature flag hygiene
        - **Sable** — dark mode rollout
        - **Tundra** — cold storage pricing
        - **Umber** — brand refresh implementation
        - **Vessel** — container base images
        - **Wharf** — deploy queue fairness
        - **Xenon** — load test harness
        - **Yarrow** — accessibility audit fixes
        - **Zephyr** — websocket connection pooling
        - **Anvil** — build cache warming
        - **Bramble** — dependency update automation
        - **Cobalt** — API version sunset
        - **Drift** — config drift detection
        - **Ellipse** — chart rendering library
        - **Fresco** — image pipeline thumbnails
        - **Gully** — log ingestion sampling
        - **Hollow** — orphaned record cleanup
        - **Ingot** — billing proration engine
        - **Jetty** — edge routing rules
        - **Kite** — status page automation
        - **Ledger** — double-entry backfill
        - **Moss** — test flake quarantine
        - **Nectar** — customer feedback tagging

        <!-- notes: The deliberately-too-much slide. Forty entries land on the floor step and the card scrolls — the fit report will tell the author to split it, or to make it two lists and get columns. -->
      MARKDOWN
      spanish: "## Problema\n\nLas personas nuevas necesitan saber qué paso completar.\n\n## Resultado\n\nUna lista breve muestra el siguiente paso.",
      japanese: "## 目標\n\n障害の影響を小さくし、復旧までの時間を短縮します。\n\n## 次のステップ\n\n復旧手順を自動で検証します。",
      arabic: "## الملخص\n\nتقارن هذه المذكرة بين الجلسات قصيرة العمر وتدوير الرموز.\n\n## الخطوة التالية\n\nتشغيل تجربة محكومة لقياس الأمان."
    }.freeze

    LONG_DOCUMENT_SECTIONS = [
      "Executive summary", "Customer problem", "Audience", "Principles", "Goals", "Non-goals",
      "Jobs to be done", "Information architecture", "Web navigation", "iOS navigation", "Android navigation",
      "Small-screen table of contents", "Workspace creation", "Invitations", "Roles and permissions",
      "Document placement", "Folder behavior", "Search", "Activity", "Notifications", "Empty states",
      "Loading and offline states", "Accessibility", "Localization", "Analytics", "Privacy", "Performance budgets",
      "Migration", "Rollout", "Support readiness", "Risks", "Open questions", "Decision log", "Appendix: terminology"
    ].freeze

    def call
      puts "Seeding reusable development data..."
      with_reproducible_faker do
        users = seed_users
        plan_types = seed_plan_types
        # Before the documents: this rename has to land on an empty folder,
        # or seed_documents would create RENAMED_FOLDER_TO first and the
        # rename would collide with it.
        seed_renamed_folder(users)
        plans = seed_documents(users, plan_types)
        seed_retitled_document(plans)
        seed_folder_descriptions(users)
        seed_collaboration_showcase(users, plans)
        seed_agent_organization_run(users, plans)
      end

      puts "Done! #{User.count} users, #{Plan.count} documents, #{Folder.count} folders, #{Tag.count} tags, " \
        "#{PlanType.count} document types, #{CommentThread.count} comment threads, " \
        "#{Reference.count} references, and #{LibraryEvent.count} library events."
    end

    def seed_users
      USERS.index_with do |attributes|
        user = User.find_or_initialize_by(external_id: "seed:#{attributes.fetch(:key)}")
        Faker::Config.locale = attributes.fetch(:locale)
        name = Faker::Name.name
        Faker::Config.locale = :en
        user.assign_attributes(
          name: name,
          username: attributes.fetch(:key),
          email: Faker::Internet.unique.email(name: name),
          title: Faker::Job.title,
          team: Faker::Company.industry,
          admin: attributes.fetch(:admin, false),
          metadata: user.metadata.to_h.merge("development_seed" => true)
        )
        user.save!
        user.library
        user
      end.transform_keys { |attributes| attributes.fetch(:key) }
    end

    def seed_plan_types
      PLAN_TYPES.index_with do |attributes|
        PlanType.find_or_initialize_by(name: attributes.fetch(:name)).tap do |plan_type|
          plan_type.assign_attributes(attributes)
          plan_type.save!
        end
      end.transform_keys { |attributes| attributes.fetch(:name) }
    end

    def seed_documents(users, plan_types)
      DOCUMENTS.index_with do |definition|
        author = users.fetch(definition.fetch(:author))
        plan = find_seed_document(definition.fetch(:key), author)

        unless plan
          plan = Plans::Create.call(
            title: definition.fetch(:title),
            content: document_content(definition),
            user: author,
            plan_type_id: plan_types.fetch(definition.fetch(:type)).id,
            visibility: definition.fetch(:visibility)
          )
          plan.update!(
            archived_at: definition[:archived] ? Time.current : nil,
            metadata: plan.metadata.to_h.merge("development_seed_key" => definition.fetch(:key))
          )
        end

        plan.tag_names = definition.fetch(:tags)
        # A definition with no folder stays at the library root — either
        # because that's the point (root-level documents) or because
        # something later files it (the agent organize run).
        place(plan, definition[:folder], author) if definition[:folder]
        plan
      end.transform_keys { |definition| definition.fetch(:key) }
    end

    def find_seed_document(key, author)
      author.created_plans.detect { |plan| plan.metadata.to_h["development_seed_key"] == key }
    end

    def place(plan, path, user)
      folder = Folder.find_or_create_by_path!(path, library: user.library, created_by_user: user)
      result = Plans::Place.call(plan: plan, folder: folder, actor: user)
      raise result.error unless result.success?
    end

    # Renaming is where readable URLs earn their keep: the old address
    # keeps resolving. One folder rename leaves a prefix alias covering
    # every document under it, so /<handle>/order-platform/... still
    # lands after the folder became "LiveOrder".
    def seed_renamed_folder(users)
      author = users.fetch("sam")
      return if UrlAlias.exists?(path: "#{author.library.handle}/#{Slug.call(RENAMED_FOLDER_FROM)}")

      folder = Folder.find_or_create_by_path!(RENAMED_FOLDER_FROM,
        library: author.library, created_by_user: author)
      folder.update!(name: RENAMED_FOLDER_TO)
    end

    # A retitle leaves an exact alias behind, so a document shared under
    # its old name stays reachable — and this particular retitle makes the
    # slug collide with a sibling, which is what puts a ~suffix on one of
    # them. Skipped once the title has already moved.
    def seed_retitled_document(plans)
      document = plans.fetch("liveorder-pricing")
      return unless document.title == RETITLED_DOCUMENT_FROM

      document.update!(title: RETITLED_DOCUMENT_TO)
    end

    # Folder descriptions give agents (and readers) semantics a bare name
    # can't carry — surfaced by the library map API and the workspace UI.
    FOLDER_DESCRIPTIONS = [
      { user: "priya", path: "Engineering/Active projects", description: "Designs in flight this quarter — one document per project, review comments welcome." },
      { user: "sam", path: "Engineering/Active projects", description: "Implementation walkthroughs for systems Sam owns." },
      { user: "alex", path: "Engineering/Architecture decisions", description: "Durable ADRs — append-only; supersede rather than edit." },
      { user: "alex", path: "Reading list/Agent picks", description: "Cross-library picks filed by an agent organize run — worth a read this week." }
    ].freeze

    def seed_folder_descriptions(users)
      FOLDER_DESCRIPTIONS.each do |entry|
        user = users.fetch(entry.fetch(:user))
        folder = Folder.find_or_create_by_path!(entry.fetch(:path), library: user.library, created_by_user: user)
        folder.update!(description: entry.fetch(:description))
      end
    end

    # Everything an agent leaves behind, on one document: an attributed
    # version ("Claude (via …)" in history with token provenance), an agent
    # review comment, citation back matter, and comment threads in every
    # state a reviewer will meet — open, accepted, resolved, overlapping
    # anchors, and a general thread with no anchor at all.
    def seed_collaboration_showcase(users, plans)
      plan = plans.fetch("collab-showcase")
      author = users.fetch("priya")
      token = seed_agent_token(author)

      seed_agent_edit(plan, author, token, related_plan: plans.fetch("code-walkthrough"))
      seed_explicit_reference(plan)
      seed_comment_threads(users, plans, token)
    end

    def seed_agent_token(user)
      existing = ApiToken.find_by(user_id: user.id, name: AGENT_TOKEN_NAME)
      return existing if existing

      token, _raw = ApiToken.create_with_raw_token(
        user_id: user.id,
        name: AGENT_TOKEN_NAME,
        agent_name: AGENT_NAME,
        metadata: { "harness" => "claude-code", "development_seed" => true }
      )
      token
    end

    def seed_agent_edit(plan, author, token, related_plan:)
      # One agent-attributed version is the fixture; local edits after it
      # are the user's business.
      return if plan.plan_versions.exists?(actor_type: "local_agent")

      content = plan.current_content
      updated = content.sub(
        "Facet counts may lag content by at most one minute.",
        "Facet counts may lag content by at most one minute — measured, not aspirational: the dark-read comparison in [§4](#section-4) enforces it."
      )
      # Linked by its readable address, not its uuid — which is how an agent
      # would write it now, and which is what gets recognized as a document
      # reference rather than an outside link. If the organization run later
      # files this plan somewhere else, the link still lands: the move leaves
      # an alias behind.
      related_url = "http://localhost:3000/#{related_plan.url_path.presence || "plans/#{related_plan.id}"}"
      updated = "#{updated.rstrip}\n\n## 5. Related reading\n\n- [#{related_plan.title}](#{related_url}) — the walkthrough whose ledger spot-check pattern [§4](#section-4) reuses.\n"
      return if updated == content

      Plans::ReplaceContent.call(
        plan: plan,
        new_content: updated,
        base_revision: plan.current_revision,
        actor_type: "local_agent",
        actor_id: author.id,
        agent_name: token.agent_name,
        api_token_id: token.id,
        change_summary: "Tie the freshness bound to the dark-read check and add related reading"
      )
    end

    # Links in prose are auto-extracted; an explicit reference is for a
    # resource that matters but is never linked — here, the Redis repo.
    def seed_explicit_reference(plan)
      reference = plan.references.find_or_initialize_by(url: "https://github.com/redis/redis")
      return if reference.persisted?

      reference.assign_attributes(key: "redis", title: "redis/redis", reference_type: "repository", source: "explicit")
      reference.save!
    end

    def seed_comment_threads(users, plans, token)
      showcase = plans.fetch("collab-showcase")
      priya = users.fetch("priya")

      # Open, anchored to prose.
      seed_thread(
        plan: showcase, user: users.fetch("sam"),
        anchor: "request-local memo",
        body: "Does the memo live on the request object or in a middleware-scoped store? If it's middleware, watch out for streamed responses holding it alive."
      )

      # An agent's review remark — renders as "Claude (via Priya)".
      seed_thread(
        plan: showcase, user: priya,
        anchor: "at most one minute",
        author_type: "local_agent", agent_name: token.agent_name, api_token: token,
        body: "[§3](#section-3) states the freshness bound but nothing cites where one minute comes from — the merchandising SLA pins it at 45 s. Worth reconciling before ramp."
      )

      # Raised, answered, resolved.
      seed_thread(
        plan: showcase, user: users.fetch("alex"),
        anchor: "allkeys-lru",
        resolved_by: priya,
        body: "volatile-lru bit us on the sessions cluster — allkeys is the right call here since nothing sets TTLs."
      )

      # Overlapping anchors: an open thread nested inside a resolved one.
      seed_thread(
        plan: showcase, user: users.fetch("aiko"),
        anchor: "comparing them with cached results in the background",
        resolved_by: priya,
        body: "Is the comparison sampled or total? Total doubles ranking load for the whole dark-read window."
      )
      seed_thread(
        plan: showcase, user: users.fetch("noura"),
        anchor: "cached results in the background",
        body: "The comparison writes through to the shared tier, right? Otherwise the dark-read never warms it and the ramp threshold lies."
      )

      # Still open — nobody's resolved it yet.
      seed_thread(
        plan: showcase, user: users.fetch("mateo"),
        anchor: "no per-key TTL tuning",
        body: "Add one sentence on what happens when the version-stamp publish itself fails — that's the first question ops will ask."
      )

      # A general remark with no anchor at all.
      seed_thread(
        plan: showcase, user: users.fetch("mateo"),
        body: "Strong direction. The dark-read bar (1 in 10,000) matches what mobile checkout used for its state-machine cutover — reusing that tooling should make the rollout cheap."
      )

      # Commenting works on documents dense with code, too.
      seed_thread(
        plan: plans.fetch("code-walkthrough"), user: users.fetch("aiko"),
        anchor: "Should MAX_STACK be a merchant setting instead of a constant?",
        body: "Coffee chains stack loyalty + happy hour + volume today — three is the observed max, so promoting this to a setting can wait for a real merchant ask."
      )
    end

    def seed_thread(plan:, user:, body:, anchor: nil, author_type: "human",
      agent_name: nil, api_token: nil, resolved_by: nil)
      return if seeded_thread?(plan, body)

      thread = plan.comment_threads.new(
        plan_version: plan.current_plan_version,
        created_by_user: user,
        anchor_text: anchor,
        status: "open"
      )
      # Anchors resolve against current content; if a local edit removed the
      # anchored sentence, skip the fixture rather than fail the whole seed.
      unless thread.save
        warn "  Skipping seed comment (anchor no longer matches): #{anchor.inspect}"
        return
      end

      thread.comments.create!(
        body_markdown: body,
        author_type: author_type,
        author_id: user.id,
        agent_name: agent_name,
        api_token_id: api_token&.id
      )
      thread.resolve!(resolved_by) if resolved_by
      thread
    end

    def seeded_thread?(plan, body)
      Comment.where(comment_thread_id: plan.comment_threads.select(:id))
        .exists?(body_markdown: body)
    end

    # A bulk organize run attributed to an agent: three of Alex's loose
    # documents swept into a folder, every audit event carrying the agent
    # name, token provenance, and a shared run_id (visible via ?run_id= on
    # the API). The documents start unfiled — DOCUMENTS gives them no
    # folder — so the run is what puts them somewhere, and a re-seed finds
    # them already there and logs nothing new.
    def seed_agent_organization_run(users, plans)
      curator = users.fetch("alex")
      token = seed_agent_token(curator)
      folder = Folder.find_or_create_by_path!("Reading list/Agent picks", library: curator.library, created_by_user: curator)

      AGENT_ORGANIZED_KEYS.each do |key|
        result = Plans::Place.call(
          plan: plans.fetch(key),
          folder: folder,
          actor: curator,
          actor_type: "local_agent",
          agent_name: token.agent_name,
          api_token_id: token.id,
          run_id: AGENT_ORGANIZE_RUN_ID,
          event_metadata: { "source" => "development_seed" }
        )
        raise result.error unless result.success?
      end
    end

    def document_content(definition)
      return long_document_content if definition[:long]

      fixture = CONTENT_FIXTURES[definition[:fixture]]
      parts = [ "# #{definition.fetch(:title)}" ]

      # Fixtures that are complete document bodies — no lorem filler around them.
      if %i[spanish japanese arabic code_walkthrough collab_showcase slideshow_deck pattern_showcase].include?(definition[:fixture])
        parts << fixture
        return parts.join("\n\n")
      end

      parts << Faker::Lorem.paragraph(sentence_count: 3)
      definition.fetch(:sections, 3).times do
        heading = Faker::Lorem.words(number: 3).join(" ").capitalize
        parts << "## #{heading}\n\n#{Faker::Lorem.paragraph(sentence_count: 3)}"
      end
      parts << fixture if fixture
      parts.join("\n\n")
    end

    def long_document_content
      sections = LONG_DOCUMENT_SECTIONS.map do |heading|
        "## #{heading}\n\n#{Faker::Lorem.paragraph(sentence_count: 3)}"
      end.join("\n\n")

      <<~MARKDOWN
        # The complete guide to launching shared workspaces

        #{Faker::Lorem.paragraph(sentence_count: 3)}

        #{sections}
      MARKDOWN
    end

    def with_reproducible_faker
      previous_random = Faker::Config.random
      previous_locale = Faker::Config.locale
      Faker::Config.random = Random.new(12_345)
      Faker::Config.locale = :en
      Faker::UniqueGenerator.clear
      yield
    ensure
      Faker::Config.random = previous_random
      Faker::Config.locale = previous_locale
      Faker::UniqueGenerator.clear
    end
  end
end
