module CoPlan
  # A deterministic, idempotent dataset for exercising CoPlan's development UI.
  # Existing seed documents keep local content edits; missing records are restored
  # on the next run and seed-owned metadata remains consistent.
  module DevelopmentSeed
    module_function

    USERS = [
      { key: "alex", name: "Alex Morgan", username: "alex", email: "alex@example.com", title: "Staff Engineer", team: "Platform", admin: true },
      { key: "priya", name: "Priya Shah", username: "priya", email: "priya@example.com", title: "Product Manager", team: "Growth" },
      { key: "mateo", name: "Mateo García", username: "mateo", email: "mateo@example.com", title: "Senior Designer", team: "Mobile" },
      { key: "aiko", name: "佐藤 愛子", username: "aiko", email: "aiko@example.com", title: "Engineering Manager", team: "Reliability" },
      { key: "noura", name: "نورا الخطيب", username: "noura", email: "noura@example.com", title: "Security Engineer", team: "Trust" },
      { key: "sam", name: "Sam Okafor", username: "sam", email: "sam@example.com", title: "Data Scientist", team: "Insights" }
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
        tags: %w[architecture database], visibility: "published", folder: "Engineering/Architecture decisions",
        content: <<~MARKDOWN
          # Use UUIDv7 identifiers

          We will use time-sortable UUIDv7 identifiers for new application records.
        MARKDOWN
      },
      {
        key: "api-gateway", author: "alex", type: "RFC", title: "RFC: Consolidating edge authentication in the API gateway",
        tags: %w[api security infrastructure], visibility: "published", folder: "Engineering/Active projects",
        content: <<~MARKDOWN
          # Consolidating edge authentication in the API gateway

          ## Context

          Three public services currently validate credentials independently. Their behavior has drifted, and clients receive inconsistent errors.

          ## Proposal

          Move credential validation to the gateway while leaving resource authorization in each service.

          ```mermaid
          flowchart LR
            Client --> Gateway
            Gateway --> Identity[Identity service]
            Gateway --> Catalog[Catalog API]
            Gateway --> Billing[Billing API]
            Catalog --> DB[(Catalog database)]
            Billing --> Ledger[(Ledger)]
          ```

          ## Rollout

          1. Mirror validation decisions without enforcement.
          2. Compare decisions and resolve mismatches.
          3. Enable enforcement for internal clients, then external clients.

          ## Open questions

          - Where should rate-limit identity be derived?
          - How long should revoked credentials remain cached?
        MARKDOWN
      },
      {
        key: "mobile-checkout", author: "mateo", type: "Design Doc", title: "Mobile checkout: resilient state transitions when the network disappears",
        tags: %w[mobile reliability payments], visibility: "published", folder: "Product/Mobile",
        content: <<~MARKDOWN
          # Mobile checkout under unreliable networks

          ## Goals

          Preserve the customer's intent, prevent duplicate charges, and make recovery understandable.

          ## State model

          ```mermaid
          stateDiagram-v2
            [*] --> Editing
            Editing --> Submitting: Pay
            Submitting --> Confirmed: accepted
            Submitting --> Retryable: timeout
            Retryable --> Submitting: retry
            Retryable --> Cancelled: cancel
            Confirmed --> [*]
            Cancelled --> [*]
          ```

          ## Offline behavior

          The client stores an idempotency key and a redacted checkout snapshot before sending the request. It never reports success without server confirmation.

          ## Accessibility

          Status changes are announced without stealing focus. Recovery actions use explicit labels rather than color alone.
        MARKDOWN
      },
      {
        key: "spanish-brief", author: "mateo", type: "Product Brief", title: "Mejoras para la experiencia de incorporación",
        tags: %w[onboarding product localization], visibility: "published", folder: "Product/Discovery",
        content: <<~MARKDOWN
          # Mejoras para la experiencia de incorporación

          ## Problema

          Las personas nuevas no saben qué paso completar después de crear su cuenta.

          ## Resultado esperado

          Una lista breve y personalizada muestra el siguiente paso, explica su valor y permite omitir tareas no relevantes.

          ## Métricas

          - Tiempo hasta completar la primera tarea
          - Porcentaje de cuentas activas después de siete días
          - Tasa de abandono por paso
        MARKDOWN
      },
      {
        key: "japanese-roadmap", author: "aiko", type: "Roadmap", title: "信頼性向上ロードマップ — 2027年前半",
        tags: %w[reliability roadmap], visibility: "published", folder: "Operations/Reliability",
        content: <<~MARKDOWN
          # 信頼性向上ロードマップ

          ## 目標

          障害の影響を小さくし、復旧までの時間を短縮します。

          ## 第1四半期

          - 重要なユーザーフローのSLOを定義する
          - アラートの重複を減らす
          - 復旧手順を自動で検証する

          ## 第2四半期

          - 地域フェイルオーバー演習
          - キャパシティ予測の導入
          - インシデントレビューの改善
        MARKDOWN
      },
      {
        key: "arabic-research", author: "noura", type: "Research Note", title: "بحث: تقليل مخاطر سرقة الجلسات",
        tags: %w[security research authentication], visibility: "published", folder: "Research/Security",
        content: <<~MARKDOWN
          # تقليل مخاطر سرقة الجلسات

          ## الملخص

          تقارن هذه المذكرة بين الجلسات قصيرة العمر، وتدوير الرموز، وربط الجلسة بالجهاز.

          ## النتائج الأولية

          - تقليل مدة الجلسة يحد من نافذة الهجوم.
          - تدوير الرموز يحتاج إلى كشف موثوق لإعادة الاستخدام.
          - ربط الجلسة بخصائص متغيرة قد يمنع مستخدمين شرعيين.

          ## الخطوة التالية

          تشغيل تجربة محكومة تقيس الأمان ومعدل طلبات تسجيل الدخول الجديدة.
        MARKDOWN
      },
      {
        key: "incident-runbook", author: "aiko", type: "Runbook", title: "Payments API latency incident runbook",
        tags: %w[operations payments on-call], visibility: "published", folder: "Operations/Runbooks",
        content: <<~MARKDOWN
          # Payments API latency incident runbook

          ## Trigger

          Use this runbook when p95 latency exceeds 800 ms for ten minutes.

          ## Triage

          1. Confirm whether errors and saturation increased with latency.
          2. Compare regions and client versions.
          3. Check the latest deploy and dependency health.

          ## Mitigation

          Roll back a correlated deploy or shed optional enrichment calls. Do not increase timeouts before identifying the constrained resource.

          ## Escalation

          Page the database owner when connection utilization exceeds 85%. Page the ledger owner when authorization latency is isolated downstream.
        MARKDOWN
      },
      {
        key: "experiment-results", author: "sam", type: "Research Note", title: "Search ranking experiment #42",
        tags: %w[search experimentation data], visibility: "published", folder: "Research/Experiments",
        content: <<~MARKDOWN
          # Search ranking experiment #42

          ## Hypothesis

          Boosting recently edited documents will improve successful search sessions without reducing result diversity.

          ## Result

          The treatment increased successful sessions by **2.8%** with a 95% confidence interval of **1.1–4.5%**.

          | Metric | Control | Treatment |
          | --- | ---: | ---: |
          | Successful sessions | 61.2% | 62.9% |
          | Reformulation rate | 18.4% | 17.7% |
          | Unique results opened | 2.3 | 2.3 |

          ## Decision

          Ship the boost at 50%, monitor for two weeks, then expand.
        MARKDOWN
      },
      {
        key: "draft-notes", author: "priya", type: "General", title: "Untitled thoughts on activation",
        tags: %w[product draft], visibility: "draft", folder: "Personal notes",
        content: <<~MARKDOWN
          # Activation notes

          What if the first-run experience began with a real task instead of a product tour?

          ## Questions

          - Which task has the shortest time to value?
          - Can we infer intent without another form?
        MARKDOWN
      },
      {
        key: "archived-proposal", author: "alex", type: "RFC", title: "Retired proposal: weekly XML exports",
        tags: %w[archive integrations], visibility: "published", archived: true, folder: "Engineering/Archive",
        content: <<~MARKDOWN
          # Weekly XML exports

          This proposal was retired after customer interviews showed a preference for incremental webhooks and CSV downloads.
        MARKDOWN
      },
      {
        key: "emoji-title", author: "priya", type: "Product Brief", title: "Faster feedback loops ⚡",
        tags: %w[collaboration product], visibility: "published", folder: "Product/Discovery",
        content: <<~MARKDOWN
          # Faster feedback loops ⚡

          ## Idea

          Let reviewers react to a specific proposal before composing detailed feedback.

          ## Guardrail

          Reactions supplement comments; they never replace a required approval or accessibility label.
        MARKDOWN
      },
      {
        key: "long-title", author: "noura", type: "Design Doc",
        title: "Designing a privacy-preserving audit trail for delegated administrative actions across regional data boundaries",
        tags: %w[security privacy compliance], visibility: "published", folder: "Engineering/Architecture decisions",
        content: <<~MARKDOWN
          # Privacy-preserving audit trail

          ## Requirements

          Every delegated action is attributable and tamper-evident while sensitive payload fields remain in their region of origin.

          ## Design

          Regional writers store the complete event and publish a signed, redacted envelope to the global index. Investigators request privileged fields through the existing approval workflow.

          ```mermaid
          sequenceDiagram
            participant A as Administrator
            participant R as Regional writer
            participant G as Global index
            A->>R: Delegated action
            R->>R: Store complete event
            R->>G: Signed redacted envelope
            G-->>A: Receipt ID
          ```

          ## Retention

          Envelopes remain globally searchable for one year. Region-specific policy controls complete event retention.
        MARKDOWN
      },
      {
        key: "long-mobile-toc", author: "priya", type: "Product Brief", title: "The complete guide to launching shared workspaces across web, iOS, and Android",
        tags: %w[collaboration mobile launch], visibility: "published", folder: "Product/Launches/Shared workspace",
        content: nil
      }
    ].freeze

    LONG_DOCUMENT_SECTIONS = [
      [ "Executive summary", "Shared workspaces let a group collect plans, decisions, and operational knowledge without changing who owns the source documents." ],
      [ "Customer problem", "Teams currently reproduce links in chat, bookmarks, and spreadsheets. The copies drift and new teammates cannot tell which collection is authoritative." ],
      [ "Audience", "The first release serves teams of 5–50 people coordinating a product launch or an operational program." ],
      [ "Principles", "Preserve document ownership, make access legible, and keep common organization tasks reversible." ],
      [ "Goals", "Create a workspace, invite collaborators, organize documents, and understand recent activity from every supported client." ],
      [ "Non-goals", "This release does not replace project management, synchronize external drives, or introduce custom permission roles." ],
      [ "Jobs to be done", "A lead can assemble the current context; a reviewer can find decisions; a new teammate can orient themselves without asking for a link dump." ],
      [ "Information architecture", "Workspace navigation separates stable collections from recency-driven activity. Search spans both without moving documents." ],
      [ "Web navigation", "The web client uses a persistent sidebar, keyboard navigation, and direct URLs for every folder." ],
      [ "iOS navigation", "The iOS client uses a compact root list and preserves the last open folder when switching tabs." ],
      [ "Android navigation", "Android follows the same hierarchy while using platform-native back behavior and predictive back previews." ],
      [ "Small-screen table of contents", "The document outline is independently scrollable so every section remains reachable without pushing the article off screen." ],
      [ "Workspace creation", "Creation asks only for a name. Defaults are useful immediately and can be refined after the first document is added." ],
      [ "Invitations", "Invitations identify the workspace, inviter, granted access, and expiration before the recipient accepts." ],
      [ "Roles and permissions", "Owners manage access; editors organize content; viewers browse and comment. Source-document permissions remain authoritative." ],
      [ "Document placement", "Adding a document creates a placement, not a copy. The same document may appear in several workspaces." ],
      [ "Folder behavior", "Folders support three levels, clear breadcrumbs, spring-loaded drag targets, and an explicit move action." ],
      [ "Search", "Results explain whether a match came from title, content, author, or tags and retain the active workspace scope." ],
      [ "Activity", "The activity feed groups noisy operations and highlights decisions, comments, access changes, and newly added documents." ],
      [ "Notifications", "Notifications are opt-in by workspace and bundled to avoid sending one message for every organizational change." ],
      [ "Empty states", "Each empty state explains the value of the surface and offers one primary next action." ],
      [ "Loading and offline states", "Clients preserve the visible hierarchy during refresh and distinguish cached content from confirmed server state." ],
      [ "Accessibility", "All organization flows support keyboard and screen readers, visible focus, reduced motion, and 200% text scaling." ],
      [ "Localization", "Layouts tolerate long labels and mixed writing directions. Dates, counts, and sorting follow the viewer's locale." ],
      [ "Analytics", "Measure workspace activation, successful document discovery, invitation acceptance, and seven-day returning collaboration." ],
      [ "Privacy", "Private drafts never surface through workspace discovery. Audit events record access changes without copying document contents." ],
      [ "Performance budgets", "Cached navigation responds within 100 ms; server-backed folder changes acknowledge within one second at p95." ],
      [ "Migration", "Existing personal folders remain personal. Users choose which collections to promote into shared workspaces." ],
      [ "Rollout", "Begin with internal teams, then a small customer cohort, then regional availability after reliability gates pass." ],
      [ "Support readiness", "Support receives troubleshooting guides, permission diagrams, and a safe impersonation-free diagnostic view." ],
      [ "Risks", "Permission confusion, notification fatigue, and deep hierarchies are the primary adoption risks." ],
      [ "Open questions", "Should viewers be able to suggest folder moves? Which events deserve email? How should inactive workspaces be presented?" ],
      [ "Decision log", "Record changes to permissions, hierarchy limits, rollout gates, and client parity expectations here." ],
      [ "Appendix: terminology", "A workspace is a shared collection; a placement points to a document; a folder organizes placements." ]
    ].freeze

    def call
      puts "Seeding reusable development data..."
      users = seed_users
      plan_types = seed_plan_types
      plans = seed_documents(users, plan_types)
      seed_shared_library_examples(users, plans)

      puts "Done! #{User.count} users, #{Plan.count} documents, #{Folder.count} folders, #{Tag.count} tags, and #{PlanType.count} document types."
    end

    def seed_users
      USERS.index_with do |attributes|
        user = User.find_or_initialize_by(external_id: "seed:#{attributes.fetch(:key)}")
        user.assign_attributes(attributes.except(:key).merge(metadata: user.metadata.to_h.merge("development_seed" => true)))
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
          content = definition[:content] || long_document_content
          plan = Plans::Create.call(
            title: definition.fetch(:title),
            content: content,
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

    def long_document_content
      sections = LONG_DOCUMENT_SECTIONS.map do |heading, body|
        "## #{heading}\n\n#{body}"
      end.join("\n\n")

      <<~MARKDOWN
        # The complete guide to launching shared workspaces

        This deliberately long seed document exercises the desktop and mobile table of contents, deep document scrolling, and headings with varied lengths.

        #{sections}
      MARKDOWN
    end
  end
end
