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
      { name: "Roadmap", icon: "map", description: "Sequenced outcomes and milestones", default_tags: [ "roadmap" ] }
    ].freeze

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
      }
    ].freeze

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
        plans = seed_documents(users, plan_types)
        seed_shared_library_examples(users, plans)
      end

      puts "Done! #{User.count} users, #{Plan.count} documents, #{Folder.count} folders, #{Tag.count} tags, and #{PlanType.count} document types."
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
        place(plan, definition.fetch(:folder), author)
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

    def seed_shared_library_examples(users, plans)
      # Demonstrate that a published document can sit on someone else's shelf
      # without changing the author's organization.
      place(plans.fetch("api-gateway"), "Reading list/Security", users.fetch("noura"))
      place(plans.fetch("experiment-results"), "Research to discuss", users.fetch("alex"))
    end

    def document_content(definition)
      return long_document_content if definition[:long]

      fixture = CONTENT_FIXTURES[definition[:fixture]]
      parts = [ "# #{definition.fetch(:title)}" ]

      # Fixtures that are complete document bodies — no lorem filler around them.
      if %i[spanish japanese arabic code_walkthrough].include?(definition[:fixture])
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
