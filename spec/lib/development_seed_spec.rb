require "rails_helper"
require Rails.root.join("db/seeds/development")

RSpec.describe CoPlan::DevelopmentSeed do
  describe ".call" do
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
        CoPlan::ApiToken.count
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
        CoPlan::ApiToken.count
      ]).to eq(counts)
      expect(CoPlan::User.order(:external_id).pluck(:name, :email, :title, :team)).to eq(generated_users)

      seeded_plans = CoPlan::Plan.select { |plan| plan.metadata.to_h.key?("development_seed_key") }
      expect(seeded_plans.size).to be >= 12
      expect(seeded_plans.map(&:visibility)).to include("draft", "published")
      expect(seeded_plans).to include(be_archived)
      expect(seeded_plans.map { |plan| plan.plan_type.name }.uniq.size).to be >= 7
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
      plan.current_plan_version.update!(content_markdown: "# Locally edited content", content_sha256: nil)

      described_class.call

      expect(plan.reload.title).to eq("Locally edited title")
      expect(plan.current_content).to eq("# Locally edited content")
    end
  end
end
