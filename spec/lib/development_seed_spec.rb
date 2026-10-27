require "rails_helper"
require "coplan/development_seed"

RSpec.describe CoPlan::DevelopmentSeed do
  describe ".call" do
    it "provides human, AI, unknown, and mixed writing examples and preserves edits when re-seeded" do
      described_class.call
      expect(seeded_plan("writing-human").writing_provenance_summary.dig("shares", "human")).to eq(1.0)
      legacy = seeded_plan("writing-legacy")
      expect(legacy.writing_provenance_summary.dig("shares", "human")).to eq(1.0)
      expect(legacy.writing_provenance_backfill).to eq("legacy_revision" => 1, "revision" => 1, "finalized_revision" => 1, "policy_version" => 2)
      early = seeded_plan("writing-legacy-unknown")
      expect(early.writing_provenance_summary.dig("shares", "unknown")).to eq(1.0)
      expect(early.current_plan_version.created_at).to eq(Time.utc(2026, 7, 9))
      ai = seeded_plan("writing-ai")
      expect(ai.writing_provenance_summary.dig("shares", "ai")).to eq(1.0)
      expect(ai.writing_provenance_summary.fetch("contributors").first).to include("harness" => "claude-code")
      expect(seeded_plan("writing-unknown").writing_provenance_summary.dig("shares", "unknown")).to eq(1.0)
      mixed = seeded_plan("writing-mixed")
      expect(mixed.writing_provenance_summary.fetch("counts").values).to all(be_positive)
      expect(mixed.current_revision).to eq(2)
      edited = seeded_plan("writing-word-edit")
      expect(edited.current_content).to include("may not retry")
      expect(edited.writing_provenance_summary.dig("counts", "human")).to eq(3)
      expect(edited.current_plan_version.writing_provenance.fetch("sources").values).to include(include("kind" => "human", "origin_revision" => 2, "user_name" => "Hampton"))
      expect(seeded_plan("demo-library").writing_provenance_summary.dig("counts", "ai")).to be_positive
      expect(seeded_plan("mixed-slides").writing_provenance_summary.dig("counts", "ai")).to be_positive
      counts = mixed.writing_provenance_summary.deep_dup
      described_class.call
      expect(mixed.reload.writing_provenance_summary).to eq(counts)
      legacy_summary = legacy.writing_provenance_summary.deep_dup
      expect(legacy.reload.writing_provenance_summary).to eq(legacy_summary)
      expect(early.reload.writing_provenance_summary.dig("shares", "unknown")).to eq(1.0)
      CoPlan::Plans::ReplaceContent.call(plan: mixed, new_content: "My local revision", base_revision: mixed.current_revision,
        actor_type: "human", actor_id: mixed.created_by_user_id)
      described_class.call
      expect(mixed.reload.current_content).to eq("My local revision")
      expect(seeded_plan("demo-library").current_content).to include("Writing sources", mixed.url_path)
    end

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

    it "seeds a private document redirect and preserves subsequent edits on re-seed" do
      described_class.call
      draft = seeded_plan("draft-notes")
      old_path = "hampton/personal-notes/untitled-thoughts-on-activation"
      expect(draft).to be_draft
      expect(draft.title).to eq(described_class::PRIVATE_RETITLED_DOCUMENT_TO)
      expect(CoPlan::UrlAlias.rewrite(old_path)).to eq(draft.url_path)
      expect(draft.current_content).to include("[original link](./untitled-thoughts-on-activation)")
      expect(seeded_plan("demo-library").current_content).to include("(/#{draft.url_path})")

      draft.update!(title: "My activation notes")
      CoPlan::Plans::ReplaceContent.call(plan: draft, new_content: "My local revision",
        base_revision: draft.current_revision, actor_type: "human", actor_id: draft.created_by_user_id)
      aliases = CoPlan::UrlAlias.count
      described_class.call

      expect(draft.reload.title).to eq("My activation notes")
      expect(draft.current_content).to eq("My local revision")
      expect(draft).to be_draft
      expect(CoPlan::UrlAlias.count).to eq(aliases)
      expect(CoPlan::UrlAlias.rewrite(old_path)).to eq(draft.url_path)
    end

    it "seeds agent access with paginated history and preserves user revocations" do
      described_class.call
      user = CoPlan::User.find_by!(email: "hampton@example.com")
      tokens = user.api_tokens.where("name LIKE ?", "Demo: %")
      expect(tokens.count).to eq(32)
      expect(tokens.personal.count).to eq(1)
      expect(tokens.sessions.usable.count).to eq(3)
      expect(tokens.sessions.where.not(id: tokens.usable.select(:id)).count).to eq(28)
      expect(seeded_plan("demo-library").current_content).to include("agent-access", "(/_/settings)")
      parent = tokens.personal.first
      child = tokens.find_by!(name: "Demo: Design review")
      expect(child.parent).to eq(parent)
      expect(child.metadata).to include("harness" => "claude-code", "model" => "Demo model")
      expiry = child.expires_at
      parent.revoke!
      described_class.call
      expect(tokens.count).to eq(32)
      expect(child.reload).to be_revoked
      expect(child.expires_at).to eq(expiry)
      expect(parent.reload).to be_revoked
    end

    it "seeds browser connection previews without redeemable secrets and preserves decisions" do
      described_class.call
      request = CoPlan::AgentConnectionRequest.for_user_code("C0DEC-0FFEE")
      expect(request).to be_pending
      expect(CoPlan::AgentConnectionRequest.for_user_code("DEAD0-BEEF0")).to be_expired
      expect(CoPlan::AgentConnectionRequest.for_user_code("DEC11-0ED00").status).to eq("denied")
      expect(seeded_plan("demo-library").current_content).to include("agent-connection", "user_code=C0DEC-0FFEE")
      user = CoPlan::User.find_by!(email: "hampton@example.com")
      request.decide!(user: user, approve: false)
      expiry = request.expires_at
      described_class.call
      expect(CoPlan::AgentConnectionRequest.count).to eq(3)
      expect(request.reload.status).to eq("denied")
      expect(request.expires_at).to eq(expiry)
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
      formatting = seeded_plan("formatting-gallery")
      formatting_content = formatting.current_content
      expect(formatting_content).to include("<!-- Template guidance:", "hidden when reading. -->")
      expect(formatting_content).to include("## Try bullet editing", "Press Backspace", "Press Backspace again", "- Try continuing this list with Enter")
      expect(formatting_content).to include("## Try comments", "choose Comment", "Enter to start normal text", "Use Shift-Enter", "clear its text and press Backspace again", "~~strikethrough~~", "[@alex](mention:alex)", "- [x] Define a receipt", "- [ ] Inspect retry metrics")
      expect(formatting_content).to include("- Item with a table.", "  | Alpha | Ready |", "blank item after this table")
      expect(formatting_content).to include("## Try numbered and lettered lists", "1) First numbered step.", "A) First uppercase lettered step.", "a) First lowercase lettered step.")

      thread_count = CoPlan::CommentThread.count
      reference_count = gallery.references.count
      described_class.call
      expect(CoPlan::CommentThread.count).to eq(thread_count)
      expect(gallery.references.count).to eq(reference_count)
      expect(formatting.reload.current_revision).to eq(1)
      expect(formatting.current_content).to eq(formatting_content)
    end

    it "refuses to take over an existing login and rolls back the seed" do
      existing = create(:coplan_user, email: "hampton@example.com", name: "Existing person")
      expect { described_class.call }.to raise_error(ArgumentError, /dedicated development database/)
      expect(existing.reload.name).to eq("Existing person")
      expect(CoPlan::User.count).to eq(1)
      expect(CoPlan::Plan.count).to eq(0)
    end

    it "seeds image resizing once and preserves a person's saved image width" do
      described_class.call
      plan = seeded_plan("image-resizing")
      expect(plan.current_content).to include(described_class.demo_logo_url, 'width="320"', "![CoPlan logo at natural width]")
      expect(plan.current_content).to include("This text starts at the top beside", "This paragraph deliberately starts below", "**Shift+Enter**", "**Enter**")
      expect(plan.current_content).to include("## Pasting images", "even if the other app displayed a thumbnail")
      expect(seeded_plan("demo-library").current_content).to include("(/#{plan.url_path})")
      revision = plan.current_revision
      described_class.call
      expect(plan.reload.current_revision).to eq(revision)

      resized = plan.current_content.sub('width="320"', 'width="240"')
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: resized,
        base_revision: plan.current_revision, actor_type: "human", actor_id: plan.created_by_user_id)
      described_class.call
      expect(plan.reload.current_content).to eq(resized)
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
      agent_edits = edited.plan_versions.where(actor_type: "local_agent").where("revision > 1")
      expect(agent_edits.count).to eq(7)
      expect(agent_edits.pluck(:api_token_id)).to all(be_present)
      expect(agent_edits.pluck(:operations_json)).to all(have_attributes(size: 1))

      pending = seeded_plan("pending-review").plan_collaborators.approvers
      approved = seeded_plan("approved-review").plan_collaborators.approvers
      expect(pending.count).to eq(2)
      expect(pending.pluck(:approved_at)).to eq([ nil, nil ])
      expect(approved.count).to eq(2)
      expect(approved.pluck(:approved_at)).to all(be_present)

      pending_requests = seeded_plan("pending-review").review_requests
      approved_requests = seeded_plan("approved-review").review_requests
      expect(pending_requests.pluck(:status)).to eq(%w[pending pending])
      expect(approved_requests.pluck(:status)).to eq(%w[approved approved])
      expect(approved_requests.map(&:latest_approval)).to all(be_present)
      requested = pending_requests.first
      response = CoPlan::Reviews::Respond.call(request: requested, actor: requested.reviewer,
        revision: requested.plan.current_revision, decision: "approved")

      pending.first.approve!
      thread = seeded_plan("collab-showcase").comment_threads.find_by!(status: "open")
      thread.resolve!(seeded_plan("collab-showcase").created_by_user)
      described_class.call
      expect(requested.reload.latest_approval).to eq(response)
      expect(requested.review_responses.count).to eq(1)

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

    it "preserves host-owned types whose names match legacy demos" do
      custom = create(:plan_type, name: "RFC")
      described_class.call
      expect(custom.reload).not_to be_retired_from_creation
      expect(CoPlan::PlanType.creation_order(CoPlan::PlanType.all)).to include(custom)
    end

    it "recognizes unmarked legacy types through their seeded documents" do
      owner = create(:coplan_user, external_id: "seed:alex", email: "alex@example.com")
      legacy = create(:plan_type, name: "RFC")
      plan = create(:plan, created_by_user: owner, plan_type: legacy,
        metadata: { "development_seed_key" => "api-gateway" })
      described_class.call
      expect(legacy.reload).to be_retired_from_creation
      expect(plan.reload.plan_type.name).to eq("Exploration")
    end

    it "keeps a legacy-named type active when host documents also use it" do
      owner = create(:coplan_user, external_id: "seed:alex", email: "alex@example.com")
      custom = create(:plan_type, name: "RFC")
      create(:plan, created_by_user: owner, plan_type: custom,
        metadata: { "development_seed_key" => "api-gateway" })
      host_plan = create(:plan, plan_type: custom)
      described_class.call
      expect(custom.reload).not_to be_retired_from_creation
      expect(host_plan.reload.plan_type).to eq(custom)
    end

    it "preserves edited and resolved seeded discussions on re-seeding" do
      described_class.call
      %w[collab-showcase diagram-comments table-gallery].each do |key|
        plan = seeded_plan(key)
        plan.comment_threads.each do |thread|
          thread.comments.first.update!(body_markdown: "My revised feedback")
          thread.resolve!(plan.created_by_user) if thread.status == "open"
        end
      end
      count = CoPlan::CommentThread.count
      # Simulate a pre-upgrade dataset with edited comments but no UUID map.
      %w[collab-showcase diagram-comments table-gallery].each do |key|
        plan = seeded_plan(key)
        plan.update!(metadata: plan.metadata.except("development_seed_threads"))
      end
      described_class.call
      expect(CoPlan::CommentThread.count).to eq(count)
      %w[collab-showcase diagram-comments table-gallery].each do |key|
        expect(seeded_plan(key).comment_threads.pluck(:status)).to all(eq("resolved"))
      end
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

    it "keeps review tasks and their responses when the reusable demo is reseeded" do
      described_class.call
      plan = seeded_plan("collab-showcase")
      requests = plan.review_requests.includes(:reviewer).index_by { |request| request.reviewer.username }
      expect(requests.transform_values(&:requirement)).to eq("alex" => "required", "sam" => "optional")
      request = requests.fetch("alex")
      response = CoPlan::Reviews::Respond.call(request: request, actor: request.reviewer,
        revision: plan.current_revision, decision: "approved")

      described_class.call

      expect(plan.review_requests.pluck(:id)).to match_array(requests.values.map(&:id))
      expect(request.reload.latest_approval).to eq(response)
      expect(request.review_responses.count).to eq(1)
    end

    it "preserves edits to existing seed document content and titles" do
      described_class.call
      plan = CoPlan::Plan.find { |candidate| candidate.metadata.to_h["development_seed_key"] == "api-gateway" }
      plan.update!(title: "Locally edited title")
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "# Locally edited content",
        base_revision: plan.current_revision, actor_type: "human", actor_id: plan.created_by_user_id)
      formatting = seeded_plan("formatting-gallery")
      edited_notes = formatting.current_content.sub("Template guidance:", "My edited template guidance:")
      CoPlan::Plans::ReplaceContent.call(plan: formatting, new_content: edited_notes,
        base_revision: formatting.current_revision, actor_type: "human", actor_id: formatting.created_by_user_id)

      described_class.call

      expect(plan.reload.title).to eq("Locally edited title")
      expect(plan.current_content).to eq("# Locally edited content")
      expect(formatting.reload.current_content).to eq(edited_notes)
    end
  end
end
