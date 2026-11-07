require "rails_helper"

RSpec.describe CoPlan::PlansHelper, type: :helper do
  describe "#plan_row_summary" do
    let(:plan) { create(:plan, :considering, summary: nil) }

    it "strips markdown formatting and returns a plain-text preview" do
      set_version_fixture(plan.current_plan_version,
        content_markdown: "# Heading\n\nA **bold** intro with [a link](https://example.com)."
      )
      preview = helper.plan_row_summary(plan)
      expect(preview).to include("Heading")
      expect(preview).to include("A bold intro with a link")
      expect(preview).not_to include("**")
      expect(preview).not_to include("](")
    end

    it "omits presentation delimiters from a mixed plan preview" do
      set_version_fixture(plan.current_plan_version, content_markdown: "::: {.presentation}\n\n# Opening slide\n\n:::\n\nClosing context.")

      preview = helper.plan_row_summary(plan)

      expect(preview).to include("Opening slide", "Closing context")
      expect(preview).not_to include(":::", "presentation")
    end

    it "truncates to the requested limit" do
      set_version_fixture(plan.current_plan_version, content_markdown: "word " * 100)
      preview = helper.plan_row_summary(plan, limit: 40)
      expect(preview.length).to be <= 41 # 40 chars + ellipsis
      expect(preview).to end_with("…")
    end

    it "prefers the summary block, then the generated summary, then the content" do
      plan.update!(summary: "Generated summary")
      set_version_fixture(plan.current_plan_version,
        content_markdown: "# Plan\n\n::: {.summary}\n- **Ship** the queue option.\n:::\n\nBody text.")
      expect(helper.plan_row_summary(plan.reload)).to eq("Ship the queue option.")

      set_version_fixture(plan.current_plan_version, content_markdown: "# Plan\n\nBody text.")
      expect(helper.plan_row_summary(plan.reload)).to eq("Generated summary")

      plan.update!(summary: nil)
      set_version_fixture(plan.current_plan_version, content_markdown: "# Plan\n\n::: {.summary}\n- Takeaway\n:::\n\nBody text.")
      preview = helper.plan_row_summary(plan.reload)
      expect(preview).to eq("Takeaway")
    end

    it "does not parse whole-plan text when an authored or generated summary wins" do
      plan.update!(summary: "Generated summary")
      set_version_fixture(plan.current_plan_version, content_markdown: "# Plan\n\nBody text.")
      expect(helper).not_to receive(:markdown_to_plain_text)
      expect(helper.plan_row_summary(plan.reload)).to eq("Generated summary")

      set_version_fixture(plan.current_plan_version, content_markdown: "::: {.summary}\nAuthored summary\n:::")
      expect(helper.plan_row_summary(plan.reload)).to eq("Authored summary")
    end

    it "caches extracted text without caching the generated summary decision" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      set_version_fixture(plan.current_plan_version, content_markdown: "# Plan\n\nFallback body.")
      plan.reload.update!(summary: "Generated summary")
      expect(helper).to receive(:markdown_to_plain_text).once.and_call_original
      expect(helper.plan_row_summary(plan)).to eq("Generated summary")
      plan.update!(summary: nil)
      expect(helper.plan_row_summary(plan)).to include("Fallback body.")
      expect(helper.plan_row_summary(plan)).to include("Fallback body.")
      plan.update!(summary: "New generated summary")
      expect(helper.plan_row_summary(plan)).to eq("New generated summary")
    end

    it "returns nil when the plan has no content" do
      set_version_fixture(plan.current_plan_version, content_markdown: "", content_sha256: Digest::SHA256.hexdigest(""))
      plan.reload
      expect(helper.plan_row_summary(plan)).to be_nil
    end

    it "returns nil when the plan has no version" do
      plan.update_columns(current_plan_version_id: nil)
      plan.reload
      expect(helper.plan_row_summary(plan)).to be_nil
    end
  end
end
