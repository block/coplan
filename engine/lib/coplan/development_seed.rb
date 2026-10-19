require "uri"

module CoPlan
  # A deterministic, idempotent dataset for exercising CoPlan's development UI.
  # Existing seed documents keep local content edits; missing records are restored
  # on the next run and seed-owned metadata remains consistent.
  module DevelopmentSeed
    module_function

    DEFAULT_EMAIL = "hampton@example.com".freeze
    CONTENT_ROOT = File.expand_path("../../db/demo/content", __dir__).freeze

    USERS = [
      { key: "hampton", name: "Hampton", title: "Demo owner", team: "Collaboration", admin: true },
      { key: "alex", name: "Alex Morgan", title: "Staff Engineer", team: "Platform", admin: true },
      { key: "mateo", name: "Mateo García", title: "Mobile Engineer", team: "Checkout" },
      { key: "aiko", name: "Aiko Tanaka", title: "Site Reliability Engineer", team: "Reliability" },
      { key: "noura", name: "Noura Haddad", title: "Security Engineer", team: "Trust" },
      { key: "sam", name: "Sam Chen", title: "Backend Engineer", team: "Orders" }
    ].freeze

    # Keep demo documents varied without inventing another set of types. A
    # fresh development install should offer the same chooser as a host that
    # loaded only the engine's shipped defaults.
    DEMO_TYPE_TO_DEFAULT = {
      "General" => "General",
      "RFC" => "Exploration",
      "Design Doc" => "Engineering Design",
      "ADR" => "Engineering Design",
      "Product Brief" => "Project 1-Pager",
      "Runbook" => "Technical Documentation",
      "Research Note" => "Research",
      "Roadmap" => "Implementation Plan",
      "Presentation" => "Presentation",
      "Scratchpad" => "Scratchpad", "PRD" => "PRD", "Test Plan" => "Test Plan", "Handoff" => "Handoff"
    }.freeze

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
      { key: "writing-legacy", author: "hampton", type: "General", title: "Writing sources: rebuilt editor history",
        tags: %w[demo provenance], visibility: "published", folder: "Demo content/Writing sources", group: "Writing sources", writing_source: "legacy",
        showcase: "Historical editor input rebuilt as human written; later pasted input stays Unknown" },
      { key: "writing-human", author: "hampton", type: "General", title: "Writing sources: human written",
        tags: %w[demo provenance], visibility: "published", folder: "Demo content/Writing sources", group: "Writing sources", writing_source: "human",
        showcase: "Person icon; recorded human input throughout" },
      { key: "writing-ai", author: "hampton", type: "General", title: "Writing sources: AI written",
        tags: %w[demo provenance], visibility: "published", folder: "Demo content/Writing sources", group: "Writing sources", writing_source: "ai",
        showcase: "Robot icon; Claude Code attribution; inspect the source of each word" },
      { key: "writing-unknown", author: "hampton", type: "General", title: "Writing sources: pasted or unknown",
        tags: %w[demo provenance], visibility: "published", folder: "Demo content/Writing sources", group: "Writing sources", writing_source: "unknown",
        showcase: "Unknown origin with a known human contributor" },
      { key: "writing-mixed", author: "hampton", type: "General", title: "Writing sources: people, agents, and paste",
        tags: %w[demo provenance], visibility: "published", folder: "Demo content/Writing sources", group: "Writing sources", writing_source: "mixed",
        showcase: "All three categories; source highlights and a subsequent agent contribution" },
      { key: "writing-word-edit", author: "hampton", type: "General", title: "Writing sources: one word changes the meaning",
        tags: %w[demo provenance], visibility: "published", folder: "Demo content/Writing sources", group: "Writing sources", writing_source: "ai",
        showcase: "Hover the human-added word not to see Hampton, version, and time" },
      { key: "diagram-comments", author: "hampton", type: "Design Doc", title: "Flowchart: comment on nodes and connections",
        tags: %w[demo diagrams], visibility: "published", folder: "Demo content/Diagrams", group: "Diagrams",
        showcase: "Flowchart with seeded node and edge discussions; press C to select an element" },
      { key: "entity-relationships", author: "hampton", type: "Design Doc", title: "Entity relationships: workspaces and invitations",
        tags: %w[demo diagrams], visibility: "published", folder: "Demo content/Diagrams", group: "Diagrams",
        showcase: "Mermaid ER diagram; whole-diagram commenting" },
      { key: "class-model", author: "hampton", type: "Design Doc", title: "Class diagram: delivery adapters",
        tags: %w[demo diagrams], visibility: "published", folder: "Demo content/Diagrams", group: "Diagrams",
        showcase: "Mermaid class diagram; whole-diagram commenting" },
      { key: "single-slide", author: "hampton", type: "Presentation", title: "One slide: the workspace launch decision",
        tags: %w[demo slides], visibility: "published", folder: "Demo content/Presentations", group: "Presentations",
        showcase: "One-slide presentation with speaker notes" },
      { key: "mixed-slides", author: "hampton", type: "Presentation", title: "Mixed document: prose and two embedded decks",
        tags: %w[demo slides], visibility: "published", folder: "Demo content/Presentations", group: "Presentations",
        showcase: "Prose before, between, and after two decks; diagrams, code, tables, and notes" },
      { key: "reference-gallery", author: "hampton", type: "General", title: "References: every supported reference type",
        tags: %w[demo references], visibility: "published", folder: "Demo content/References", group: "References",
        showcase: "CoPlan document, repository, pull request, external document, web link, footnote, and named citation" },
      { key: "table-gallery", author: "hampton", type: "Research Note", title: "Tables: cells, links, empty values, and wide data",
        tags: %w[demo tables], visibility: "published", folder: "Demo content/Rich text", group: "Tables and rich text",
        showcase: "Cell discussion, repeated labels, empty cells, links, and a wide expandable table" },
      { key: "formatting-gallery", author: "hampton", type: "General", title: "Rich text: headings, tasks, code, quotes, and footnotes",
        tags: %w[demo markdown], visibility: "published", folder: "Demo content/Rich text", group: "Tables and rich text",
        showcase: "Markdown formatting, reversible bullet typing, list exit, task toggles, code languages, image, mention, and footnotes" },
      { key: "image-resizing", author: "hampton", type: "General", title: "Images: resize and snap to full width",
        tags: %w[demo images editor], visibility: "published", folder: "Demo content/Rich text", group: "Tables and rich text",
        showcase: "Editor corner resizing, saved Markdown width, undo, and snap to natural full width" },
      { key: "type-scratchpad", author: "hampton", type: "Scratchpad", title: "Scratchpad: workspace naming ideas",
        tags: %w[demo types], visibility: "published", folder: "Demo content/Plan types", group: "Plan type examples" },
      { key: "type-prd", author: "hampton", type: "PRD", title: "PRD: workspace invitations",
        tags: %w[demo types], visibility: "published", folder: "Demo content/Plan types", group: "Plan type examples" },
      { key: "type-test-plan", author: "hampton", type: "Test Plan", title: "Test plan: invitation acceptance",
        tags: %w[demo types], visibility: "published", folder: "Demo content/Plan types", group: "Plan type examples" },
      { key: "type-handoff", author: "hampton", type: "Handoff", title: "Handoff: invitation delivery operations",
        tags: %w[demo types], visibility: "published", folder: "Demo content/Plan types", group: "Plan type examples" },
      { key: "type-implementation-plan", author: "hampton", type: "Roadmap", title: "Implementation plan: invitation rollout",
        tags: %w[demo types], visibility: "published", folder: "Demo content/Plan types", group: "Plan type examples" },
      {
        key: "untouched-document", author: "hampton", type: "Design Doc", title: "Workspace invitations: first draft",
        tags: %w[collaboration demo], visibility: "published", folder: "Demo scenarios",
        scenario: "One version, no edits, no comments, no reviewers"
      },
      {
        key: "many-small-edits", author: "hampton", type: "Design Doc", title: "Workspace invitations: seven small improvements",
        tags: %w[collaboration demo], visibility: "published", folder: "Demo scenarios",
        scenario: "Eight versions with small attributed diffs"
      },
      {
        key: "pending-review", author: "hampton", type: "Design Doc", title: "Workspace invitations: awaiting approval",
        tags: %w[collaboration demo], visibility: "published", folder: "Demo scenarios",
        scenario: "Alex and Noura have pending approvals"
      },
      {
        key: "approved-review", author: "hampton", type: "Design Doc", title: "Workspace invitations: approved rollout",
        tags: %w[collaboration demo], visibility: "published", folder: "Demo scenarios",
        scenario: "Both approvers have approved; no pending approvals"
      },
      {
        key: "one-line-decision", author: "alex", type: "ADR", title: "Use UUIDv7 identifiers",
        tags: %w[architecture database], visibility: "published", folder: "Engineering/Architecture decisions"
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
        key: "draft-notes", author: "hampton", type: "General", title: "Untitled thoughts on activation",
        tags: %w[product draft], visibility: "draft", folder: "Personal notes"
      },
      {
        key: "archived-proposal", author: "alex", type: "RFC", title: "Retired proposal: weekly XML exports",
        tags: %w[archive integrations], visibility: "published", archived: true, folder: "Engineering/Archive"
      },
      {
        key: "emoji-title", author: "hampton", type: "Product Brief", title: "Faster feedback loops ⚡",
        tags: %w[collaboration product], visibility: "published", folder: "Product/Discovery"
      },
      {
        key: "long-title", author: "noura", type: "Design Doc",
        title: "Designing a privacy-preserving audit trail for delegated administrative actions across regional data boundaries",
        tags: %w[security privacy compliance], visibility: "published", folder: "Engineering/Architecture decisions", fixture: :sequence_diagram
      },
      {
        key: "long-mobile-toc", author: "hampton", type: "Product Brief", title: "The complete guide to launching shared workspaces across web, iOS, and Android",
        tags: %w[collaboration mobile launch], visibility: "published", folder: "Product/Launches/Shared workspace"
      },
      {
        key: "code-walkthrough", author: "sam", type: "Design Doc", title: "Order discount engine: implementation walkthrough",
        tags: %w[pricing api design], visibility: "published", folder: "Engineering/Active projects", fixture: :code_walkthrough
      },
      {
        key: "collab-showcase", author: "hampton", type: "Design Doc", title: "Search latency: cutting p95 with a two-tier cache",
        tags: %w[search performance caching], visibility: "published", folder: "Engineering/Active projects", fixture: :collab_showcase
      },
      {
        key: "launch-deck", author: "hampton", type: "Presentation", title: "Shared workspaces launch — readout deck",
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
        tags: %w[product data], visibility: "published"
      },
      {
        key: "agent-pick-postmortem", author: "alex", type: "Runbook", title: "Postmortem: the Tuesday cache stampede",
        tags: %w[operations reliability], visibility: "published"
      },
      {
        key: "agent-pick-vendors", author: "alex", type: "General", title: "Vendor evaluation notes",
        tags: %w[procurement], visibility: "published"
      }
    ].freeze

    # Identity the collaboration fixtures attribute agent activity to —
    # renders as "Claude (via <user>)" in history, comments, and audit events.
    AGENT_NAME = "Claude"
    AGENT_TOKEN_NAME = "Claude Code (development seed)"
    AGENT_ORGANIZE_RUN_ID = "development-seed-organize-run"

    REVIEW_SCENARIOS = {
      "pending-review" => false,
      "approved-review" => true
    }.freeze

    SMALL_EDITS = [
      [ "a 500 ms timeout", "a 250 ms timeout", "Tighten the request timeout" ],
      [ "retry twice", "retry once", "Bound duplicate work during an outage" ],
      [ "retain receipts for 7 days", "retain receipts for 30 days", "Align receipt retention with support needs" ],
      [ "sample 1% of requests", "sample 5% of requests", "Increase the dark-read sample" ],
      [ "ramp to 10%", "ramp to 20%", "Expand the first rollout cohort" ],
      [ "alert above 2% errors", "alert above 1% errors", "Catch regressions earlier" ],
      [ "review every month", "review every week", "Schedule weekly rollout checks" ]
    ].freeze

    def call(base_url: ENV.fetch("COPLAN_DEMO_BASE_URL", "http://localhost:3000"))
      raise "Demo data is only available in development and test environments." unless Rails.env.local?

      base_url = base_url.delete_suffix("/")
      uri = URI.parse(base_url)
      raise ArgumentError, "Demo base URL must be an http(s) URL without a query or fragment" unless %w[http https].include?(uri.scheme) && uri.host && !uri.query && !uri.fragment

      puts "Seeding reusable development data..."
      catalog = ActiveRecord::Base.transaction do
        CoPlan::Engine.load_seed
        users = seed_users
        plan_types = seed_plan_types
        # Before the documents: this rename has to land on an empty folder,
        # or seed_documents would create RENAMED_FOLDER_TO first and the
        # rename would collide with it.
        seed_renamed_folder(users)
        plans = seed_documents(users, plan_types)
        seed_bundled_images(plans)
        seed_retitled_document(plans)
        seed_folder_descriptions(users)
        seed_collaboration_showcase(users, plans, base_url: base_url)
        seed_agent_organization_run(users, plans)
        seed_small_edits(users, plans)
        seed_writing_sources(users, plans)
        seed_writing_word_edit(users, plans)
        seed_reviews(users, plans)
        seed_review_requests(users, plans)
        seed_agent_access(users)
        seed_agent_connections(users) if CoPlan.configuration.agent_connection_enabled?
        seed_content_discussions(users, plans)
        seed_reference_gallery(plans, base_url: base_url)
        catalog = seed_catalog(users, plans, plan_types, base_url: base_url)
        seed_writing_history(users, plans, catalog)
        catalog
      end

      puts "Done! #{User.count} users, #{Plan.count} documents, #{Folder.count} folders, #{Tag.count} tags, " \
        "#{PlanType.count} document types, #{CommentThread.count} comment threads, " \
        "#{Reference.count} references, and #{LibraryEvent.count} library events."
      puts "Demo login: #{DEFAULT_EMAIL} (example host only; no password)."
      puts "Demo library: #{base_url}/#{catalog.url_path}"
    end

    def seed_users
      USERS.index_with do |attributes|
        email = "#{attributes.fetch(:key)}@example.com"
        external_id = "seed:#{attributes.fetch(:key)}"
        if User.where(email: email).where.not(external_id: external_id).exists?
          raise ArgumentError, "Demo login #{email} belongs to another identity. Use a dedicated development database."
        end
        user = User.find_by(external_id: external_id)
        # Upgrade the previous default demo identity in place. Keeping its
        # UUID preserves documents, version attribution, comments, and tokens.
        legacy_owner = attributes.fetch(:key) == "hampton" && user.nil? &&
          User.find_by(external_id: "seed:priya")
        user ||= legacy_owner || User.new(external_id: external_id)
        user.assign_attributes(
          external_id: external_id,
          name: attributes.fetch(:name),
          username: attributes.fetch(:key),
          email: email,
          title: attributes.fetch(:title),
          team: attributes.fetch(:team),
          admin: attributes.fetch(:admin, false),
          metadata: user.metadata.to_h.merge("development_seed" => true)
        )
        user.save!
        library = user.library
        library.update!(handle: "hampton") if legacy_owner && library.handle == "priya"
        user
      end.transform_keys { |attributes| attributes.fetch(:key) }
    end

    def seed_plan_types
      PlanTypes::InstallDefaults.call
      DEMO_TYPE_TO_DEFAULT.each do |legacy_name, shipped_name|
        next if legacy_name == shipped_name

        legacy_type = PlanType.find_by_name(legacy_name)
        next unless legacy_type && legacy_seed_type?(legacy_type) && !legacy_type.retired_from_creation?

        legacy_type.update!(metadata: legacy_type.metadata.to_h.merge("retired_from_creation" => true))
      end
      DEMO_TYPE_TO_DEFAULT.transform_values { |name| PlanType.find_by_name(name) }
    end

    def legacy_seed_type?(type)
      return true if type.metadata.to_h["development_seed"] == true

      # The original seed had no type marker. Only infer ownership when all
      # documents using it are known fixtures with their expected demo owner.
      plans = type.plans.includes(:created_by_user).to_a
      definitions = DOCUMENTS.index_by { |definition| definition.fetch(:key) }
      plans.any? && plans.all? do |plan|
        definition = definitions[plan.metadata.to_h["development_seed_key"]]
        definition && plan.created_by_user.external_id == "seed:#{definition.fetch(:author)}"
      end
    end

    def seed_documents(users, plan_types)
      DOCUMENTS.index_with do |definition|
        author = users.fetch(definition.fetch(:author))
        plan = find_seed_document(definition.fetch(:key), author)

        unless plan
          content = document_content(definition)
          origin = definition.fetch(:writing_source, "ai")
          token = seed_agent_token(author) if origin == "ai"
          input_sources = case origin
          when "human" then { "runs" => [ [ content.encode(Encoding::UTF_16LE).bytesize / 2, "human" ] ] }
          when "mixed"
            boundary = content.index("## Imported context")
            { "runs" => [ [ content[0...boundary].encode(Encoding::UTF_16LE).bytesize / 2, "human" ],
              [ content[boundary..].encode(Encoding::UTF_16LE).bytesize / 2, "unknown" ] ] }
          end
          plan = Plans::Create.call(
            title: definition.fetch(:title),
            content: content, input_sources: input_sources,
            actor_type: origin == "ai" ? "local_agent" : "human", agent_name: token&.agent_name, api_token_id: token&.id,
            user: author,
            plan_type_id: plan_types.fetch(definition.fetch(:type)).id,
            visibility: definition.fetch(:visibility)
          )
          plan.update!(
            archived_at: definition[:archived] ? Time.current : nil,
            metadata: plan.metadata.to_h.merge("development_seed_key" => definition.fetch(:key))
          )
        end

        # Older development seeds used their own overlapping type catalog.
        # Bring only seed-owned plans onto the shipped types; leave anything
        # a developer created or retitled alone.
        shipped_type = plan_types.fetch(definition.fetch(:type))
        plan.update!(plan_type: shipped_type) if plan.plan_type_id != shipped_type.id

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
      { user: "hampton", path: "Engineering/Active projects", description: "Designs in flight this quarter — one document per project, review comments welcome." },
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
    # state a reviewer will meet — open, resolved, overlapping
    # anchors, and a general thread with no anchor at all.
    def seed_collaboration_showcase(users, plans, base_url:)
      plan = plans.fetch("collab-showcase")
      author = users.fetch("hampton")
      token = seed_agent_token(author)

      seed_agent_edit(plan, author, token, related_plan: plans.fetch("code-walkthrough"), base_url: base_url)
      seed_explicit_reference(plan)
      seed_comment_threads(users, plans, token)
    end

    # Named settings scenario: durable bootstrap, host-minted and child sessions,
    # missing identity, and enough history to exercise pagination. Never reset
    # a session someone has revoked or extend its lifetime on a later seed.
    def seed_agent_access(users)
      user = users.fetch("hampton")
      personal = seed_access_token(user, "Demo: Work laptop")
      seed_access_token(user, "Demo: Design review", parent_id: personal.id,
        agent_name: "Claude", expires_at: 7.days.from_now, last_used_at: 10.minutes.ago,
        metadata: { "harness" => "claude-code", "harness_version" => "demo", "model" => "Demo model" })
      seed_access_token(user, "Demo: Architecture research", agent_name: "Amp",
        expires_at: 2.days.from_now, last_used_at: 1.hour.ago,
        metadata: { "harness" => "amp", "model" => "Demo model" })
      seed_access_token(user, "Demo: Identity not reported", expires_at: 1.day.from_now)
      28.times do |i|
        seed_access_token(user, "Demo: Past session #{i + 1}", agent_name: "Claude",
          expires_at: (i + 1).days.ago, created_at: (i + 8).days.ago,
          revoked_at: (i.even? ? (i + 2).days.ago : nil),
          metadata: { "harness" => "claude-code" })
      end
    end

    CONNECTION_DEMOS = {
      "C0DEC-0FFEE" => [ "Demo: Browser approval", "pending" ],
      "DEAD0-BEEF0" => [ "Demo: Expired connection", "pending" ],
      "DEC11-0ED00" => [ "Demo: Declined connection", "denied" ]
    }.freeze

    def seed_agent_connections(users)
      CONNECTION_DEMOS.each do |code, (name, status)|
        digest = AgentConnectionRequest.digest(AgentConnectionRequest.normalize_code(code))
        next if AgentConnectionRequest.exists?(user_code_digest: digest)
        AgentConnectionRequest.create!(name: name, status: status,
          user: (users.fetch("hampton") if status == "denied"),
          user_code_digest: digest,
          # The redemption secret is discarded. Demo approval can never
          # hand a credential to anyone; use the helper for a real tryout.
          device_code_digest: AgentConnectionRequest.digest(SecureRandom.hex(32)),
          expires_at: code == "DEAD0-BEEF0" ? 1.minute.ago : 10.minutes.from_now)
      end
    end

    def seed_access_token(user, name, **attributes)
      ApiToken.find_by(user_id: user.id, name: name) ||
        ApiToken.create_with_raw_token(user: user, name: name, **attributes).first
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

    def seed_agent_edit(plan, author, token, related_plan:, base_url:)
      # Add one agent edit to the pristine fixture. Initial demo text also
      # has agent attribution; later local edits are the user's business.
      return unless plan.current_revision == 1

      content = plan.current_content
      updated = content.sub(
        "Facet counts may lag content by at most one minute.",
        "Facet counts may lag content by at most one minute — measured, not aspirational: the dark-read comparison in [§4](#section-4) enforces it."
      )
      # Root-mounted examples use readable URLs, which survive moves via
      # aliases. The reference resolver also recognizes mounted UUID routes;
      # use that form for a nested engine.
      related_path = if URI.parse(base_url).path.present?
        "plans/#{related_plan.id}"
      else
        related_plan.url_path.presence || "plans/#{related_plan.id}"
      end
      related_url = "#{base_url}/#{related_path}"
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
      hampton = users.fetch("hampton")

      # Open, anchored to prose.
      seed_thread(
        plan: showcase, user: users.fetch("sam"),
        anchor: "request-local memo",
        body: "Does the memo live on the request object or in a middleware-scoped store? If it's middleware, watch out for streamed responses holding it alive."
      )

      # An agent's review remark — renders as "Claude (via Hampton)".
      seed_thread(
        plan: showcase, user: hampton,
        anchor: "at most one minute",
        author_type: "local_agent", agent_name: token.agent_name, api_token: token,
        body: "[§3](#section-3) states the freshness bound but nothing cites where one minute comes from — the merchandising SLA pins it at 45 s. Worth reconciling before ramp."
      )

      # Raised, answered, resolved.
      seed_thread(
        plan: showcase, user: users.fetch("alex"),
        anchor: "allkeys-lru",
        resolved_by: hampton,
        body: "volatile-lru bit us on the sessions cluster — allkeys is the right call here since nothing sets TTLs."
      )

      # Overlapping anchors: an open thread nested inside a resolved one.
      seed_thread(
        plan: showcase, user: users.fetch("aiko"),
        anchor: "comparing them with cached results in the background",
        resolved_by: hampton,
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

    def seed_thread(plan:, user:, body:, anchor: nil, source_token: nil, author_type: "human",
      agent_name: nil, api_token: nil, resolved_by: nil)
      return if seeded_thread?(plan, body)

      # Legacy seeds had no stored UUIDs. Match their author and anchor when
      # the original comment was already edited before this upgrade.
      candidates = plan.comment_threads.where(created_by_user_id: user.id)
      if source_token
        target = Plans::SourceTargets.verifier.verified(source_token, purpose: "comment")
        candidates = candidates.where(anchor_kind: target.fetch("kind"),
          anchor_start: target.fetch("start"), anchor_end: target.fetch("end"))
      else
        candidates = candidates.where(anchor_kind: nil, anchor_text: anchor)
      end
      if (existing = candidates.first)
        remember_seed_thread(plan, body, existing)
        return
      end

      thread = plan.comment_threads.new(
        plan_version: plan.current_plan_version,
        created_by_user: user,
        anchor_text: anchor,
        source_token: source_token,
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
      remember_seed_thread(plan, body, thread)
      thread
    end

    def seeded_thread?(plan, body)
      key = Digest::SHA256.hexdigest(body)
      ids = plan.metadata.to_h.fetch("development_seed_threads", {})
      return true if ids[key] && plan.comment_threads.exists?(id: ids[key])

      # Upgrade older fixtures once, then identify them by thread UUID even
      # after a person edits or deletes the original comment.
      comment = Comment.where(comment_thread_id: plan.comment_threads.select(:id))
        .find_by(body_markdown: body)
      return false unless comment

      remember_seed_thread(plan, body, comment.comment_thread)
      true
    end

    def remember_seed_thread(plan, body, thread)
      ids = plan.metadata.to_h.fetch("development_seed_threads", {})
      plan.update!(metadata: plan.metadata.to_h.merge("development_seed_threads" =>
        ids.merge(Digest::SHA256.hexdigest(body) => thread.id)))
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
      key = definition[:fixture] || definition.fetch(:key)
      content = File.read(File.join(CONTENT_ROOT, "#{key}.md"))
      content = content.gsub("{{demo_logo_url}}") { demo_logo_url }
      content = "# #{definition.fetch(:title)}\n\n#{content}"
      if %i[slideshow_deck pattern_showcase].include?(definition[:fixture])
        "::: {.presentation}\n\n#{content}\n\n:::"
      else
        content
      end
    end

    def demo_logo_url
      ActionController::Base.helpers.asset_path("coplan/demo-logo.png")
    end

    def seed_bundled_images(plans)
      %w[mixed-slides formatting-gallery pattern-showcase].each do |key|
        plan = plans.fetch(key)
        content = document_content(DOCUMENTS.find { |entry| entry[:key] == key })
        legacy = content.gsub(demo_logo_url, "/coplan-logo.png")
        next unless content != legacy && plan.current_content == legacy

        Plans::ReplaceContent.call(plan: plan, new_content: content,
          base_revision: plan.current_revision, actor_type: "system", actor_id: plan.created_by_user_id,
          change_summary: "Use the engine's bundled demo image")
      end
    end

    def seed_small_edits(users, plans)
      plan = plans.fetch("many-small-edits")
      # Only initialize history on an untouched fixture. Re-seeding never
      # injects changes into a document someone has started working on.
      return unless plan.current_revision == 1 && plan.current_content == document_content(DOCUMENTS.find { |d| d[:key] == "many-small-edits" })

      author = users.fetch("hampton")
      token = seed_agent_token(author)
      SMALL_EDITS.each do |before, after, summary|
        Plans::ReplaceContent.call(
          plan: plan, new_content: plan.current_content.sub(before, after),
          base_revision: plan.current_revision, actor_type: "local_agent",
          actor_id: author.id, agent_name: token.agent_name, api_token_id: token.id,
          change_summary: summary
        )
      end
    end

    # A fresh checkout includes one required and one optional task. Never
    # reset a response somebody recorded while trying the feature.
    def seed_review_requests(users, plans)
      plan = plans.fetch("collab-showcase")
      [ [ "alex", "required" ], [ "sam", "optional" ] ].each do |key, requirement|
        next if plan.review_requests.where(reviewer: users.fetch(key)).exists?
        Reviews::Request.call(plan: plan, reviewer: users.fetch(key), actor: plan.created_by_user, requirement: requirement)
      end
    end

    def seed_writing_sources(users, plans)
      plan = plans.fetch("writing-mixed")
      definition = DOCUMENTS.find { |item| item[:key] == "writing-mixed" }
      return unless plan.current_revision == 1 && plan.current_content == document_content(definition)
      token = seed_agent_token(users.fetch("hampton"))
      Plans::ReplaceContent.call(plan: plan, new_content: plan.current_content + "\n\n## Agent proposal\n\nRetry transient failures with exponential backoff. Retain event IDs so consumers can safely deduplicate deliveries.\n",
        base_revision: 1, actor_type: "local_agent", actor_id: users.fetch("hampton").id,
        agent_name: token.agent_name, api_token_id: token.id, change_summary: "Add the agent's retry proposal")
    end

    def seed_writing_word_edit(users, plans)
      plan = plans.fetch("writing-word-edit")
      content = document_content(DOCUMENTS.find { |item| item[:key] == "writing-word-edit" })
      return unless plan.current_revision == 1 && plan.current_content == content
      changed = content.sub("may retry", "may not retry")
      Plans::ReplaceContent.call(plan: plan, new_content: changed, base_revision: 1,
        actor_type: "human", actor_id: users.fetch("hampton").id, change_summary: "Change retry policy with one word",
        input_sources: { "runs" => [ [ changed.encode(Encoding::UTF_16LE).bytesize / 2, "human" ] ] })
    end

    # Demo fixture origin is explicit simulation data. Reconstruct only seed-owned
    # initial versions; never replace the input evidence from a person's later edit.
    def seed_writing_history(users, plans, catalog)
      definitions = DOCUMENTS.index_by { |item| item[:key] }
      plans.merge("demo-library" => catalog).each do |key, plan|
        first = plan.plan_versions.find_by!(revision: 1)
        origin = definitions[key]&.fetch(:writing_source, "ai") || "ai"
        existing = first.writing_provenance.to_h
        if origin == "legacy" && plan.writing_provenance_backfill.nil?
          plan.update_columns(writing_provenance_backfill: { "legacy_revision" => 1, "revision" => 0 })
          WritingProvenanceJob.perform_now(plan_id: plan.id, restart: true)
          next
        end
        expected_kind = { "ai" => "ai", "unknown" => "unknown" }[origin]
        ready = existing.dig("write_source", "origin_revision") && (!expected_kind || existing.dig("summary", "counts", expected_kind) == existing.dig("summary", "total"))
        next if ready
        if origin == "ai"
          token = seed_agent_token(users.fetch("hampton"))
          first.writing_provenance = first.writing_provenance.to_h.merge("write_source" => {
            "kind" => "ai", "user_id" => first.actor_id, "agent_name" => token.agent_name,
            "harness" => "claude-code", "harness_name" => "Claude" })
          first.update_columns(writing_provenance: first.writing_provenance)
        elsif origin == "unknown"
          first.update_columns(writing_provenance: first.writing_provenance.to_h.merge("write_source" => { "kind" => "unknown", "user_id" => first.actor_id }))
        end
        WritingProvenanceJob.perform_now(plan_id: plan.id, restart: true)
      end
    end

    def seed_reviews(users, plans)
      REVIEW_SCENARIOS.each do |key, approved|
        plan = plans.fetch(key)
        %w[alex noura].each do |reviewer|
          collaborator = plan.plan_collaborators.find_or_initialize_by(user: users.fetch(reviewer))
          unless collaborator.persisted?
            collaborator.assign_attributes(role: "approver", added_by_user: users.fetch("hampton"))
            collaborator.approved_at = Time.current if approved
            collaborator.save!
          end
          next if plan.review_requests.where(reviewer: users.fetch(reviewer)).exists?

          request = Reviews::Request.call(plan: plan, reviewer: users.fetch(reviewer), actor: plan.created_by_user)
          Reviews::Respond.call(request: request, actor: request.reviewer, revision: plan.current_revision, decision: "approved") if approved
        end
      end
    end

    def seed_content_discussions(users, plans)
      selections = [
        [ "diagram-comments", "mermaid_node", "Queue[", "Node Queue", "Should this queue have a separate retry budget per workspace?" ],
        [ "diagram-comments", "mermaid_edge", "retry", "Connection Queue → Delivery", "What backoff do we use on this retry connection?" ],
        [ "entity-relationships", "mermaid_diagram", "erDiagram", "Entire diagram", "Does accepting an invitation create membership atomically with consuming it?" ],
        [ "class-model", "mermaid_diagram", "classDiagram", "Entire diagram", "Should both adapters expose the same delivery outcome codes?" ],
        [ "long-title", "mermaid_diagram", "sequenceDiagram", "Entire diagram", "Does the receipt response wait for the region-local audit write?" ],
        [ "mobile-checkout", "mermaid_diagram", "stateDiagram", "Entire diagram", "Where does an expired receipt transition after reconnecting?" ],
        [ "table-gallery", "table_cell", "queued", "Delivery status", "How long can this receipt remain queued before the admin sees a warning?" ]
      ]
      selections.each do |key, kind, fragment, label, body|
        plan = plans.fetch(key)
        next if seeded_thread?(plan, body)

        content = plan.current_content
        range = Plans::SourceTargets.new(content).ranges.find do |target_kind, start, finish|
          target_kind == kind && content[start...finish].include?(fragment)
        end
        next unless range # Preserve locally edited examples whose target was removed.

        _, start, finish = range
        data = { "digest" => Digest::SHA256.hexdigest(content), "kind" => kind,
          "start" => start, "end" => finish, "label" => label }
        token = Plans::SourceTargets.verifier.generate(data, purpose: "comment")
        seed_thread(plan: plan, user: users.fetch("alex"), body: body, source_token: token)
      end
    end

    def seed_reference_gallery(plans, base_url:)
      plan = plans.fetch("reference-gallery")
      definition = DOCUMENTS.find { |entry| entry[:key] == "reference-gallery" }
      return unless plan.current_content == document_content(definition)

      target = plans.fetch("diagram-comments")
      content = plan.current_content.sub("{{demo_document_url}}", "#{base_url}/plans/#{target.id}")
      Plans::ReplaceContent.call(plan: plan, new_content: content,
        base_revision: plan.current_revision, actor_type: "system", actor_id: plan.created_by_user_id,
        change_summary: "Link the reference gallery to the commentable flowchart")
      reference = plan.references.find_or_initialize_by(url: "https://github.com/rails/rails")
      reference.assign_attributes(source: "explicit", reference_type: "repository", key: "rails", title: "Rails repository")
      reference.save!
      References::ExtractFromContent.call(plan: plan)
    end

    def connection_demo_links(base_url)
      return "" unless CoPlan.configuration.agent_connection_enabled?
      prefix = URI.parse(base_url).path
      <<~MARKDOWN
        The **agent-connection** scenario previews browser approval. These requests
        have no redeemable secret; run the helper from [Agent setup](#{prefix}/_/agent/setup)
        to try a real local connection. Re-seeding preserves decisions and expiry.

        - [Pending approval](#{prefix}/_/agent/connect?user_code=C0DEC-0FFEE) — match code `C0DEC-0FFEE`.
        - [Expired request](#{prefix}/_/agent/connect?user_code=DEAD0-BEEF0).
        - [Declined request](#{prefix}/_/agent/connect?user_code=DEC11-0ED00).
      MARKDOWN
    end

    def seed_catalog(users, plans, plan_types, base_url:)
      author = users.fetch("hampton")
      existing = find_seed_document("demo-library", author)

      groups = DOCUMENTS.group_by do |definition|
        if definition[:group]
          definition[:group]
        elsif %i[flowchart state_diagram sequence_diagram].include?(definition[:fixture])
          "Diagrams"
        elsif %i[table code_walkthrough].include?(definition[:fixture])
          "Tables and rich text"
        elsif definition[:fixture] == :collab_showcase
          "References"
        elsif definition[:scenario]
          "Review scenarios"
        elsif definition[:type] == "Presentation"
          "Presentations"
        elsif definition[:key].start_with?("liveorder-", "agent-pick-") || %w[draft-notes archived-proposal pricing-rules].include?(definition[:key])
          "Libraries and visibility"
        else
          "More documents"
        end
      end
      order = [ "Diagrams", "Presentations", "Tables and rich text", "References", "Writing sources",
        "Plan type examples", "More documents", "Libraries and visibility", "Review scenarios" ]
      sections = order.filter_map do |heading|
        definitions = groups[heading]
        next unless definitions

        links = definitions.map do |definition|
          plan = plans.fetch(definition.fetch(:key))
          state = definition[:showcase] || definition[:scenario] || {
            flowchart: "Architecture flowchart; node and edge commenting",
            state_diagram: "State diagram; whole-diagram commenting",
            sequence_diagram: "Sequence diagram; whole-diagram commenting",
            slideshow_deck: "Multi-slide launch deck with speaker notes and tasks",
            pattern_showcase: "Slide layouts: title, columns, code, diagram, image, quote, and table"
          }[definition[:fixture]] || definition[:fixture]&.to_s&.tr("_", " ") || "Document and readable URLs"
          # Relative links stay in the browser's current host and avoid
          # duplicating the entire index in the extracted References list.
          path = "#{URI.parse(base_url).path}/#{plan.url_path}"
          title = plan.title.gsub(/[\\\[\]]/) { |character| "\\#{character}" }.gsub(/[\r\n]+/, " ")
          "- [#{title}](#{path}) — **#{plan.plan_type.name}**. #{state}. `#{definition.fetch(:key)}`"
        end
        "## #{heading}\n\n#{links.join("\n")}"
      end
      type_links = plans.values.group_by { |plan| plan.plan_type.name }.sort.map do |name, examples|
        plan = examples.find { |example| example.created_by_user_id == author.id } || examples.first
        path = "#{URI.parse(base_url).path}/#{plan.url_path}"
        "- **#{name}** — [open an example](#{path})"
      end
      content = <<~MARKDOWN
        # Demo library

        Sign in as **#{DEFAULT_EMAIL}** in the example host. Start with a content surface:
        diagrams, slides, tables, rich text, or references. Every link below names its
        actual plan type and what you can try. Hampton owns the focused content examples.

        Jump to [Diagrams](#diagrams), [Presentations](#presentations),
        [Tables and rich text](#tables-and-rich-text), [References](#references),
        or [Every plan type](#every-plan-type).

        Flowcharts support node and connection comments. Other Mermaid types support
        whole-diagram comments. Browse first; press **C** or choose **Comment** when
        you want to comment. Diagrams and tables include seeded discussions to open.

        This is the shared demo and development library shipped with CoPlan. Each key is
        a named scenario. Start here when trying a feature, taking screenshots, or
        extending the examples. Re-seeding adds missing documents and keeps local edits,
        approvals, and resolved discussions. Use a fresh database for the initial states.

        #{sections.join("\n\n")}

        ## Agent access

        [Open agent access settings](#{URI.parse(base_url).path}/_/settings) as Hampton.
        The **agent-access** scenario includes a personal token for a work laptop,
        child and host-authenticated sessions, missing identity, and paginated history.
        Search by agent or harness, inspect session details, or revoke access.
        Re-seeding preserves revocations and expiry dates.
        #{connection_demo_links(base_url)}

        ## Every plan type

        These are the twelve types shipped with the engine, each with a real document.
        The document type is separate from the content it contains: a design can include
        a diagram, and a presentation can mix prose with decks.

        #{type_links.join("\n")}

        ## Contributing an example

        Add a Markdown file to `engine/db/demo/content`, a definition to `DOCUMENTS` in
        `engine/lib/coplan/development_seed.rb`, and a behavioral assertion to
        `spec/lib/development_seed_spec.rb`. Run `bin/rails coplan:demo:seed`.
      MARKDOWN
      if existing
        # Refresh an untouched generated index as the library grows. A local
        # edit to the index is preserved just like any other demo document.
        return existing unless existing.current_plan_version.content_sha256 == existing.metadata["development_catalog_sha"]

        Plans::ReplaceContent.call(plan: existing, new_content: content,
          base_revision: existing.current_revision, actor_type: "local_agent", actor_id: author.id,
          agent_name: seed_agent_token(author).agent_name, api_token_id: seed_agent_token(author).id,
          change_summary: "Refresh the demo library index")
        existing.update!(metadata: existing.metadata.merge("development_catalog_sha" => existing.current_plan_version.content_sha256))
        return existing
      end

      plan = Plans::Create.call(title: "Demo library", content: content, user: author,
        actor_type: "local_agent", agent_name: seed_agent_token(author).agent_name, api_token_id: seed_agent_token(author).id,
        plan_type_id: plan_types.fetch("General").id, visibility: "published")
      plan.update!(metadata: plan.metadata.to_h.merge("development_seed_key" => "demo-library",
        "development_catalog_sha" => plan.current_plan_version.content_sha256))
      plan.tag_names = %w[demo examples]
      plan
    end
  end
end
