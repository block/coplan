require "rails_helper"

RSpec.describe "Plan versions", type: :request do
  let(:author) { create(:coplan_user) }
  let(:viewer) { create(:coplan_user) }
  let(:plan) { create(:plan, :published, created_by_user: author) }

  before { sign_in_as(viewer) }

  describe "GET /plans/:plan_id/versions/:id" do
    it "renders a version to any viewer" do
      get plan_version_path(plan, plan.current_plan_version)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(plan.title)
    end
  end

  describe "GET /plans/:plan_id/versions/:id/diff" do
    it "diffs against the previous revision" do
      v2 = create(:plan_version, plan: plan, revision: 2,
                  content_markdown: "# Plan\n\nChanged line.\n", actor_id: author.id)
      plan.update!(current_plan_version: v2, current_revision: 2)

      get diff_plan_version_path(plan, v2)
      expect(response).to have_http_status(:ok)
      # Assert on text, not raw HTML: Diffy shells out to the platform diff
      # binary, and GNU vs BSD diff pair changed lines differently — the
      # inline <strong> word-highlights can split the phrase mid-word.
      expect(Nokogiri::HTML(response.body).text).to include("Changed line")
    end

    it "handles revision 1, which has no previous version" do
      get diff_plan_version_path(plan, plan.current_plan_version)
      expect(response).to have_http_status(:ok)
    end
  end
end
