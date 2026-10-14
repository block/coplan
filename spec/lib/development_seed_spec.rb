require "rails_helper"
require "coplan/development_seed"

RSpec.describe CoPlan::DevelopmentSeed do
  describe ".call" do
    def seeded_plan(key)
      CoPlan::Plan.all.detect { |plan| plan.metadata.to_h["development_seed_key"] == key }
    end

    it "refuses non-local environments before creating data" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

      expect { described_class.call }.to raise_error(/only available in development and test/)
      expect(CoPlan::User.count).to eq(0)
      expect(CoPlan::Plan.count).to eq(0)
    end

    it "creates fixed demo logins and a linked index of every named scenario" do
      described_class.call(base_url: "http://localhost:3100")

      expect(CoPlan::User.find_by!(email: "hampton@example.com").external_id).to eq("seed:hampton")
      expect(CoPlan::User.find_by!(email: "alex@example.com")).to be_admin
      catalog = seeded_plan("demo-library")
      described_class::DOCUMENTS.each do |definition|
        plan = seeded_plan(definition.fetch(:key))
        expect(catalog.current_content).to include("(/#{plan.url_path})")
        expect(plan.current_content).not_to match(/lorem ipsum/i)
        decoded_path = URI::DEFAULT_PARSER.unescape(plan.url_path)
        expect(CoPlan::Urls::Resolve.call(handle: decoded_path.split("/").first,
          slug_path: decoded_path.split("/").drop(1).join("/")).plan).to eq(plan)
      end
      expect(seeded_plan("collab-showcase").references.find_by(reference_type: "plan").url).to start_with("http://localhost:3100/")
    end

    it "ships every demo content file and the installer inside the engine gem" do
      specification = Gem::Specification.load(CoPlan::Engine.root.join("coplan.gemspec").to_s)
      expect(specification.files).to include("lib/coplan/development_seed.rb")
      expect(specification.files).to include("app/assets/images/coplan/demo-logo.png")
      described_class::DOCUMENTS.each do |definition|
        key = definition[:fixture] || definition.fetch(:key)
        expect(specification.files).to include("db/demo/content/#{key}.md")
      end
    end

    it "covers content surfaces, structural discussions, references, and every shipped plan type" do
      described_class.call
      plans = CoPlan::Plan.where.not(id: seeded_plan("demo-library").id)
      expect(plans.map { |plan| plan.plan_type.name }.uniq.sort).to eq(CoPlan::PlanType::CREATION_ORDER.sort)
      catalog = seeded_plan("demo-library").current_content
      expect(catalog.index("## Diagrams")).to be < catalog.index("## Review scenarios")
      CoPlan::PlanType::CREATION_ORDER.each { |name| expect(catalog).to include("**#{name}**") }

      flow = seeded_plan("diagram-comments")
      expect(flow.comment_threads.pluck(:anchor_kind).sort).to eq(%w[mermaid_edge mermaid_node])
      %w[entity-relationships class-model long-title mobile-checkout].each do |key|
        expect(seeded_plan(key).comment_threads.where(anchor_kind: "mermaid_diagram").count).to eq(1)
      end
      expect(seeded_plan("table-gallery").comment_threads.where(anchor_kind: "table_cell").count).to eq(1)
      [ flow, seeded_plan("table-gallery") ].each do |plan|
        ranges = CoPlan::Plans::SourceTargets.new(plan.current_content).ranges
        plan.comment_threads.each do |thread|
          expect(ranges).to include([ thread.anchor_kind, thread.anchor_start, thread.anchor_end ])
        end
      end
      single = CoPlan::ContentRegions::Split.call(seeded_plan("single-slide").current_content)
      expect(single.regions.count { |region| region.kind == :presentation }).to eq(1)
      mixed = CoPlan::ContentRegions::Split.call(seeded_plan("mixed-slides").current_content)
      expect(mixed.regions.map(&:kind)).to eq(%i[document presentation document presentation document])
      gallery = seeded_plan("reference-gallery")
      expect(gallery.references.pluck(:reference_type).uniq.sort).to eq(CoPlan::Reference::REFERENCE_TYPES.sort)
      expect(gallery.references.find_by!(reference_type: "plan").target_plan).to eq(flow)
      expect(gallery.references.explicit.count).to eq(1)
      expect(gallery.current_content).not_to include("{{demo_document_url}}")
      expect(seeded_plan("mixed-slides").current_content).to include(described_class.demo_logo_url)
      expect(seeded_plan("formatting-gallery").current_content).not_to include("{{demo_logo_url}}", "/coplan-logo.png")

      thread_count = CoPlan::CommentThread.count
      reference_count = gallery.references.count
      described_class.call
      expect(CoPlan::CommentThread.count).to eq(thread_count)
      expect(gallery.references.count).to eq(reference_count)
    end

    it "refuses to take over an existing login and rolls back the seed" do
      existing = create(:coplan_user, email: "hampton@example.com", name: "Existing person")
      expect { described_class.call }.to raise_error(ArgumentError, /dedicated development database/)
      expect(existing.reload.name).to eq("Existing person")
      expect(CoPlan::User.count).to eq(1)
      expect(CoPlan::Plan.count).to eq(0)
    end

    it "upgrades only untouched host image URLs and preserves edited image examples" do
      described_class.call
      plan = seeded_plan("pattern-showcase")
      legacy = plan.current_content.gsub(described_class.demo_logo_url, "/coplan-logo.png")
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: legacy,
        base_revision: plan.current_revision, actor_type: "system", actor_id: plan.created_by_user_id)
      described_class.call
      expect(plan.reload.current_content).to include(described_class.demo_logo_url)

      edited = "#{legacy}\n\nMy own speaker notes."
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: edited,
        base_revision: plan.current_revision, actor_type: "human", actor_id: plan.created_by_user_id)
      described_class.call
      expect(plan.reload.current_content).to eq(edited)
    end

    it "supports links and references for a mounted engine" do
      described_class.call(base_url: "http://localhost:3100/coplan")
      expect(seeded_plan("demo-library").current_content).to include("(/coplan/hampton/")
      reference = seeded_plan("collab-showcase").references.find_by!(reference_type: "plan")
      expect(reference.target_plan).to eq(seeded_plan("code-walkthrough"))
      expect(reference.url).to start_with("http://localhost:3100/coplan/plans/")
    end

    it "upgrades the previous default owner without replacing their work" do
      legacy = create(:coplan_user, external_id: "seed:priya", username: "priya",
        email: "priya@example.com", name: "Priya Shah", metadata: { "development_seed" => true })
      library = legacy.library
      draft = create(:plan, created_by_user: legacy, title: "My local draft",
        metadata: { "development_seed_key" => "draft-notes" })
      content = draft.current_content

      described_class.call
      described_class.call

      expect(CoPlan::User.find_by!(email: "hampton@example.com").id).to eq(legacy.id)
      expect(legacy.reload.external_id).to eq("seed:hampton")
      expect(library.reload.handle).to eq("hampton")
      expect(CoPlan::UrlAlias.find_by!(path: "priya").target_path).to eq("hampton")
      expect(draft.reload.created_by_user_id).to eq(legacy.id)
      expect(draft.title).to eq("My local draft")
      expect(draft.current_content).to eq(content)
      expect(CoPlan::User.count).to eq(described_class::USERS.size)
    end

    it "seeds untouched, frequently edited, pending, and approved scenarios" do
      described_class.call
      untouched = seeded_plan("untouched-document")
      expect(untouched.current_revision).to eq(1)
      expect(untouched.comment_threads).to be_empty
      expect(untouched.plan_collaborators).to be_empty

      edited = seeded_plan("many-small-edits")
      expect(edited.current_revision).to eq(8)
      expect(edited.plan_versions.where(actor_type: "local_agent").count).to eq(7)
      expect(edited.plan_versions.where(actor_type: "local_agent").pluck(:api_token_id)).to all(be_present)
      expect(edited.plan_versions.where(actor_type: "local_agent").pluck(:operations_json)).to all(have_attributes(size: 1))

      pending = seeded_plan("pending-review").plan_collaborators.approvers
      approved = seeded_plan("approved-review").plan_collaborators.approvers
      expect(pending.count).to eq(2)
      expect(pending.pluck(:approved_at)).to eq([ nil, nil ])
      expect(approved.count).to eq(2)
      expect(approved.pluck(:approved_at)).to all(be_present)

      pending.first.approve!
      thread = seeded_plan("collab-showcase").comment_threads.find_by!(status: "open")
      thread.resolve!(seeded_plan("collab-showcase").created_by_user)
      described_class.call

      expect(pending.reload.where(approved_at: nil).count).to eq(1)
      expect(thread.reload.status).to eq("resolved")
      expect(edited.reload.current_revision).to eq(8)
    end

    it "refreshes a generated index while preserving a locally edited index" do
      described_class.call
      plan = seeded_plan("api-gateway")
      plan.update!(title: "Gateway architecture, revised")
      described_class.call
      catalog = seeded_plan("demo-library")
      expect(catalog.current_content).to include("Gateway architecture, revised")

      CoPlan::Plans::ReplaceContent.call(plan: catalog, new_content: "# My demo tour",
        base_revision: catalog.current_revision, actor_type: "human", actor_id: catalog.created_by_user_id)
      described_class.call
      expect(catalog.reload.current_content).to eq("# My demo tour")
    end

    it "retires old demo-only types while preserving their existing documents" do
      old_type = create(:plan_type, name: "RFC", metadata: { "development_seed" => true })
      existing = create(:plan, plan_type: old_type)

      described_class.call

      expect(old_type.reload).to be_retired_from_creation
      expect(existing.reload.plan_type).to eq(old_type)
      expect(CoPlan::PlanType.creation_order(CoPlan::PlanType.all).size).to eq(12)
    end

    it "preserves an unmarked host-owned legacy type" do
      custom = create(:plan_type, name: "RFC", description: "Our host review format")
      metadata = custom.metadata.deep_dup
      described_class.call
      expect(custom.reload.metadata).to eq(metadata)
      expect(CoPlan::PlanType.creation_order(CoPlan::PlanType.all)).to include(custom)
    end

    %w[text general source].each do |kind|
      it "preserves an edited and resolved #{kind} seed discussion" do
        described_class.call
        plan = seeded_plan(kind == "source" ? "diagram-comments" : "collab-showcase")
        scope = plan.comment_threads
        thread = case kind
        when "source" then scope.where.not(anchor_kind: nil).first!
        when "general" then scope.where(anchor_kind: nil, anchor_text: nil).first!
        else scope.where(anchor_kind: nil).where.not(anchor_text: [ nil, "" ]).first!
        end
        comment = thread.comments.first!
        comment.update!(body_markdown: "My edited #{kind} discussion")
        thread.resolve!(plan.created_by_user) unless thread.status == "resolved"
        ids = plan.comment_threads.pluck(:id).sort
        notification_count = CoPlan::Notification.count
        described_class.call
        expect(plan.comment_threads.pluck(:id).sort).to eq(ids)
        expect(thread.reload.status).to eq("resolved")
        expect(comment.reload.body_markdown).to eq("My edited #{kind} discussion")
        expect(CoPlan::Notification.count).to eq(notification_count)
      end
    end

    it "creates a varied, idempotent development dataset" do
      described_class.call

      counts = [
        CoPlan::User.count,
        CoPlan::Plan.count,
        CoPlan::Folder.count,
        CoPlan::Tag.count,
        CoPlan::PlanType.count,
        CoPlan::PlanPlacement.count,
        CoPlan::PlanVersion.count,
        CoPlan::CommentThread.count,
        CoPlan::Comment.count,
        CoPlan::Reference.count,
        CoPlan::LibraryEvent.count,
        CoPlan::ApiToken.count,
        CoPlan::PlanCollaborator.count
      ]
      generated_users = CoPlan::User.order(:external_id).pluck(:name, :email, :title, :team)

      described_class.call

      expect([
        CoPlan::User.count,
        CoPlan::Plan.count,
        CoPlan::Folder.count,
        CoPlan::Tag.count,
        CoPlan::PlanType.count,
        CoPlan::PlanPlacement.count,
        CoPlan::PlanVersion.count,
        CoPlan::CommentThread.count,
        CoPlan::Comment.count,
        CoPlan::Reference.count,
        CoPlan::LibraryEvent.count,
        CoPlan::ApiToken.count,
        CoPlan::PlanCollaborator.count
      ]).to eq(counts)
      expect(CoPlan::User.order(:external_id).pluck(:name, :email, :title, :team)).to eq(generated_users)

      seeded_plans = CoPlan::Plan.select { |plan| plan.metadata.to_h.key?("development_seed_key") }
      expect(seeded_plans.size).to be >= 12
      expect(seeded_plans.map(&:visibility)).to include("draft", "published")
      expect(seeded_plans).to include(be_archived)
      expect(seeded_plans.map { |plan| plan.plan_type.name }.uniq.size).to be >= 7
      expect(CoPlan::PlanType.pluck(:name).sort).to eq(CoPlan::PlanType::CREATION_ORDER.sort)
      expect(seeded_plans.flat_map(&:tag_names).uniq.size).to be >= 12
      expect(seeded_plans.map(&:title)).to include(a_string_matching(/信頼性/), a_string_matching(/تقليل/))

      long_document = seeded_plans.find { |plan| plan.metadata["development_seed_key"] == "long-mobile-toc" }
      expect(long_document.current_content.scan(/^## /).size).to be >= 30
      expect(seeded_plans.count { |plan| plan.current_content.include?("```mermaid") }).to be >= 3
      expect(CoPlan::Folder.where.not(parent_id: nil)).to exist
    end

    it "seeds a collaboration showcase covering attribution, comments, references, and library events" do
      described_class.call

      showcase = CoPlan::Plan.find { |plan| plan.metadata.to_h["development_seed_key"] == "collab-showcase" }

      # An agent-attributed version with token provenance in the history.
      agent_version = showcase.plan_versions.find_by(actor_type: "local_agent")
      expect(agent_version.agent_name).to eq("Claude")
      expect(agent_version.api_token).to be_present
      expect(agent_version.actor_user).to eq(showcase.created_by_user)

      # Threads in every reviewer-facing state, all anchors resolved.
      threads = showcase.comment_threads
      expect(threads.pluck(:status)).to include("open", "resolved")
      expect(threads.where(anchor_text: nil)).to exist
      anchored = threads.where.not(anchor_text: nil)
      expect(anchored.pluck(:anchor_start)).to all(be_present)

      # Overlapping anchors: an open thread nested inside a resolved one.
      resolved = anchored.find_by(status: "resolved", created_by_user: CoPlan::User.find_by!(username: "aiko"))
      nested = anchored.find_by(created_by_user: CoPlan::User.find_by!(username: "noura"))
      expect(nested.anchor_start).to be > resolved.anchor_start
      expect(nested.anchor_end).to be <= resolved.anchor_end

      # An agent comment rendering as "Claude (via …)".
      agent_comment = CoPlan::Comment.find_by(author_type: "local_agent")
      expect(agent_comment.agent_name).to eq("Claude")
      expect(agent_comment.api_token).to be_present

      # Citations extracted from footnotes, a resolved plan reference, and
      # one explicitly curated resource.
      expect(showcase.references.extracted.where(reference_type: "link").count).to be >= 2
      plan_reference = showcase.references.find_by(reference_type: "plan")
      expect(plan_reference.target_plan).to be_present
      expect(showcase.references.explicit.pluck(:reference_type)).to eq([ "repository" ])

      # A grouped, agent-attributed organize run in the audit log.
      run_events = CoPlan::LibraryEvent.where(run_id: described_class::AGENT_ORGANIZE_RUN_ID)
      expect(run_events.count).to eq(3)
      expect(run_events.pluck(:actor_type).uniq).to eq([ "local_agent" ])
      expect(run_events.pluck(:agent_name).uniq).to eq([ "Claude" ])
      expect(run_events.pluck(:api_token_id)).to all(be_present)

      # Folder semantics agents can read.
      expect(CoPlan::Folder.where.not(description: nil).count).to be >= 4
    end

    it "preserves edits to existing seed document content and titles" do
      described_class.call
      plan = CoPlan::Plan.find { |candidate| candidate.metadata.to_h["development_seed_key"] == "api-gateway" }
      plan.update!(title: "Locally edited title")
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "# Locally edited content",
        base_revision: plan.current_revision, actor_type: "human", actor_id: plan.created_by_user_id)

      described_class.call

      expect(plan.reload.title).to eq("Locally edited title")
      expect(plan.current_content).to eq("# Locally edited content")
    end
  end
end
