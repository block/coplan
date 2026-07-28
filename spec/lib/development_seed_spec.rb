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
        CoPlan::PlanPlacement.count
      ]
      generated_users = CoPlan::User.order(:external_id).pluck(:name, :email, :title, :team)

      described_class.call

      expect([
        CoPlan::User.count,
        CoPlan::Plan.count,
        CoPlan::Folder.count,
        CoPlan::Tag.count,
        CoPlan::PlanType.count,
        CoPlan::PlanPlacement.count
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
