require "rails_helper"

RSpec.describe CoPlan::ApplicationHelper, type: :helper do
  describe "#plan_og_description" do
    let(:plan) { create(:plan, :published, title: "My Plan") }

    it "includes the plan state and author" do
      result = helper.plan_og_description(plan)
      expect(result).to include("Plan")
      expect(result).to include(plan.created_by_user.name)
    end

    it "labels private and archived plans" do
      draft = create(:plan, :draft)
      archived = create(:plan, archived_at: 1.day.ago)
      expect(helper.plan_og_description(draft)).to start_with("Private")
      expect(helper.plan_og_description(archived)).to start_with("Archived")
    end

    it "includes a content excerpt when content is present" do
      plan.current_plan_version.update!(content_markdown: "# Overview\n\nThis is the summary of the plan.")
      result = helper.plan_og_description(plan)
      expect(result).to include("This is the summary of the plan.")
    end

    it "returns only prefix when plan has no version" do
      plan.update_columns(current_plan_version_id: nil)
      plan.reload
      result = helper.plan_og_description(plan)
      expect(result).to eq("Plan · by #{plan.created_by_user.name}")
    end

    it "truncates long content" do
      long_text = "A" * 500
      plan.current_plan_version.update!(content_markdown: long_text)
      result = helper.plan_og_description(plan)
      expect(result.length).to be <= 250
    end
  end
end
