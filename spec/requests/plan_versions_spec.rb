require "rails_helper"

RSpec.describe "Plan versions", type: :request do
  let(:author) { create(:coplan_user) }
  let(:viewer) { create(:coplan_user) }
  let(:plan) { create(:plan, :published, created_by_user: author) }

  before { sign_in_as(viewer) }

  describe "GET /plans/:plan_id/versions/:id" do
    it "renders a version to any viewer" do
      get plan_version_page_path(plan, plan.current_plan_version)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(plan.title)
    end

    it "keeps footnote definitions in a historical mixed-content version" do
      plan.current_plan_version.update!(content_markdown: <<~MD, content_sha256: nil)
        Context[^a].

        ::: {.presentation}

        # Slide

        Evidence[^b].

        :::

        [^a]: Context source.
        [^b]: Slide source.
      MD

      get plan_version_page_path(plan, plan.current_plan_version)

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("a[data-footnote-ref]").map { |ref| ref["href"] }).to eq([ "#fn-a", "#fn-b" ])
      expect(doc.css("section[data-footnotes] > ol > li").map { |item| item["id"] }).to eq(%w[fn-a fn-b])
      expect(doc.css(".markdown-rendered > section[data-footnotes]").size).to eq(1)
    end
  end

  describe "GET /plans/:plan_id/versions/:id/diff" do
    it "diffs against the previous revision" do
      v2 = create(:plan_version, plan: plan, revision: 2,
                  content_markdown: "# Plan\n\nChanged line.\n", actor_id: author.id)
      plan.update!(current_plan_version: v2, current_revision: 2)

      get plan_version_diff_page_path(plan, v2)
      expect(response).to have_http_status(:ok)
      # Assert on text, not raw HTML: Diffy shells out to the platform diff
      # binary, and GNU vs BSD diff pair changed lines differently — the
      # inline <strong> word-highlights can split the phrase mid-word.
      expect(Nokogiri::HTML(response.body).text).to include("Changed line")
    end

    it "handles revision 1, which has no previous version" do
      get plan_version_diff_page_path(plan, plan.current_plan_version)
      expect(response).to have_http_status(:ok)
    end
  end
end
