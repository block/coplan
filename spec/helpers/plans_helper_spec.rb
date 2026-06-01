require "rails_helper"

RSpec.describe CoPlan::PlansHelper, type: :helper do
  describe "#plan_content_preview" do
    let(:plan) { create(:plan, :considering) }

    it "strips markdown formatting and returns a plain-text preview" do
      plan.current_plan_version.update!(
        content_markdown: "# Heading\n\nA **bold** intro with [a link](https://example.com)."
      )
      preview = helper.plan_content_preview(plan)
      expect(preview).to include("Heading")
      expect(preview).to include("A bold intro with a link")
      expect(preview).not_to include("**")
      expect(preview).not_to include("](")
    end

    it "truncates to the requested limit" do
      plan.current_plan_version.update!(content_markdown: "word " * 100)
      preview = helper.plan_content_preview(plan, limit: 40)
      expect(preview.length).to be <= 41 # 40 chars + ellipsis
      expect(preview).to end_with("…")
    end

    it "returns nil when the plan has no content" do
      plan.current_plan_version.update_columns(content_markdown: "", content_sha256: Digest::SHA256.hexdigest(""))
      plan.reload
      expect(helper.plan_content_preview(plan)).to be_nil
    end

    it "returns nil when the plan has no version" do
      plan.update_columns(current_plan_version_id: nil)
      plan.reload
      expect(helper.plan_content_preview(plan)).to be_nil
    end
  end
end
