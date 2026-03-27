require "rails_helper"

RSpec.describe CoPlan::ApplicationHelper, type: :helper do
  describe "#plan_og_description" do
    let(:plan) { create(:plan, title: "My Plan", status: "considering") }

    it "includes status and author" do
      result = helper.plan_og_description(plan)
      expect(result).to include("Considering")
      expect(result).to include(plan.created_by_user.name)
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
      expect(result).to eq("Considering · by #{plan.created_by_user.name}")
    end

    it "truncates long content" do
      long_text = "A" * 500
      plan.current_plan_version.update!(content_markdown: long_text)
      result = helper.plan_og_description(plan)
      expect(result.length).to be <= 250
    end
  end
end
