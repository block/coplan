require "rails_helper"

RSpec.describe Plans::ReviewResponseParser do
  let(:plan_content) { "# My Plan\n\nWe use API tokens scoped to a user.\n\nNo rate limiting yet." }

  describe ".call" do
    it "parses a valid JSON array response into feedback items" do
      response = '[
        {"anchor_text": "API tokens scoped to a user", "comment": "Add token expiration."},
        {"anchor_text": "No rate limiting yet", "comment": "Add rate limiting before launch."}
      ]'

      items = described_class.call(response, plan_content: plan_content)

      expect(items).to eq([
        { anchor_text: "API tokens scoped to a user", comment: "Add token expiration." },
        { anchor_text: "No rate limiting yet", comment: "Add rate limiting before launch." }
      ])
    end

    it "handles JSON wrapped in markdown code fences" do
      response = "```json\n[{\"anchor_text\": null, \"comment\": \"Looks good.\"}]\n```"

      items = described_class.call(response, plan_content: plan_content)

      expect(items).to eq([{ anchor_text: nil, comment: "Looks good." }])
    end

    it "handles null anchor_text for general feedback" do
      response = '[{"anchor_text": null, "comment": "Overall solid plan."}]'

      items = described_class.call(response, plan_content: plan_content)

      expect(items.first[:anchor_text]).to be_nil
      expect(items.first[:comment]).to eq("Overall solid plan.")
    end

    it "demotes anchor_text that does not match plan content to unanchored" do
      response = '[{"anchor_text": "text that does not exist in the plan", "comment": "Some feedback."}]'

      items = described_class.call(response, plan_content: plan_content)

      expect(items.first[:anchor_text]).to be_nil
      expect(items.first[:comment]).to include("> text that does not exist in the plan")
      expect(items.first[:comment]).to include("Some feedback.")
    end

    it "falls back to a single unanchored comment for non-JSON responses" do
      response = "Here is my review in plain text.\n\nSome concerns about security."

      items = described_class.call(response, plan_content: plan_content)

      expect(items.length).to eq(1)
      expect(items.first[:anchor_text]).to be_nil
      expect(items.first[:comment]).to eq(response)
    end

    it "falls back to a single comment when JSON is not an array" do
      response = '{"anchor_text": "something", "comment": "not an array"}'

      items = described_class.call(response, plan_content: plan_content)

      expect(items.length).to eq(1)
      expect(items.first[:anchor_text]).to be_nil
      expect(items.first[:comment]).to eq(response)
    end

    it "handles empty anchor_text string as nil" do
      response = '[{"anchor_text": "", "comment": "General note."}]'

      items = described_class.call(response, plan_content: plan_content)

      expect(items.first[:anchor_text]).to be_nil
    end
  end
end
