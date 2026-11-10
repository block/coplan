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
      set_version_fixture(plan.current_plan_version, content_markdown: <<~MD, content_sha256: nil)
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
      expect(Nokogiri::HTML(response.body).text).to include("Empty document → v1")
    end

    context "with a range of revisions" do
      let(:v2) { create(:plan_version, plan: plan, revision: 2, content_markdown: "# Plan\n\nIntermediate wording.\n") }
      let(:v3) { create(:plan_version, plan: plan, revision: 3, content_markdown: "# Plan\n\nFinal wording.\n") }

      before do
        v2
        v3
        plan.update!(current_plan_version: v3, current_revision: 3)
      end

      it "compares the snapshot before the first checked revision with the last checked revision" do
        get plan_version_diff_page_path(plan, v3, from: 2)

        expect(response).to have_http_status(:ok)
        doc = Nokogiri::HTML(response.body)
        expect(doc.text).to include("v1 → v3", "Combined changes introduced in v2–v3")
        expect(doc.css(".diff-view .del").text).to include("Some content here")
        expect(doc.css(".diff-view .ins").text).to include("Final wording")
        expect(doc.css(".diff-view").text).not_to include("Intermediate wording")
      end

      it "includes the entire document when the range starts at the initial version" do
        get plan_version_diff_page_path(plan, v3, from: 1)

        doc = Nokogiri::HTML(response.body)
        expect(doc.text).to include("Empty document → v3")
        expect(doc.css(".diff-view .del")).to be_empty
        expect(doc.css(".diff-view .ins").text).to include("Final wording")
      end

      it "reports no net change even when intermediate versions differ" do
        set_version_fixture(v3, content_markdown: plan.plan_versions.find_by!(revision: 1).content_markdown, content_sha256: nil)
        get plan_version_diff_page_path(plan, v3, from: 2)

        expect(Nokogiri::HTML(response.body).text).to include("No document text changed across these revisions")
      end

      it "escapes document HTML in the diff" do
        set_version_fixture(v3, content_markdown: "<script>alert('unsafe')</script>", content_sha256: nil)
        get plan_version_diff_page_path(plan, v3, from: 2)

        doc = Nokogiri::HTML(response.body)
        expect(doc.css(".diff-view script")).to be_empty
        expect(doc.css(".diff-view").text).to include("<script>")
      end

      [ "0", "-1", "2junk", "4", [ "2" ] ].each do |invalid|
        it "rejects an invalid or reversed range starting at #{invalid.inspect}" do
          get plan_version_diff_page_path(plan, v3, from: invalid)
          expect(response).to have_http_status(:not_found)
        end
      end

      it "does not use a revision that only exists on a different plan" do
        other = create(:plan, :published)
        foreign_version = create(:plan_version, plan: other, revision: 4)
        get plan_version_diff_page_path(plan, foreign_version, from: 2)
        expect(response).to have_http_status(:not_found)
      end

      it "keeps unlisted plans readable by link under the existing policy" do
        plan.update!(visibility: "draft")
        get plan_version_diff_page_path(plan, v3, from: 1)
        expect(response).to have_http_status(:ok)
      end

      it "requires sign-in for a comparison" do
        delete sign_out_path
        get plan_version_diff_page_path(plan, v3, from: 1)
        expect(response).to redirect_to(sign_in_path)
      end

      it "restores a shared history range and preserves it on the full-version page" do
        get plan_history_page_path(plan, from: 2, to: 3)

        expect(response).to have_http_status(:ok)
        doc = Nokogiri::HTML(response.body)
        expect(doc.css("#plan-history input[checked]").map { |input| input["value"] }).to contain_exactly("2", "3")
        expect(doc.at_css("#version-diff").text).to include("v1 → v3")

        get plan_version_page_path(plan, v3, from: 2)
        doc = Nokogiri::HTML(response.body)
        expect(doc.text).to include("Changes from v1 to v3")
        expect(doc.at_css("a[href*='/history?']")["href"]).to include("from=2", "to=3")
      end

      it "rejects a missing end revision on history" do
        get plan_history_page_path(plan, from: 2, to: 99)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
