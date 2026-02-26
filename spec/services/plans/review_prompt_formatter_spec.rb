require "rails_helper"

RSpec.describe CoPlan::Plans::ReviewPromptFormatter do
  describe ".call" do
    it "appends JSON response format instructions to the reviewer prompt" do
      result = described_class.call(reviewer_prompt: "Review for security issues.")

      expect(result).to start_with("Review for security issues.")
      expect(result).to include("JSON array")
      expect(result).to include("anchor_text")
      expect(result).to include("comment")
    end

    it "preserves the original reviewer prompt" do
      original = "You are a scalability reviewer.\n\nFocus on database queries."
      result = described_class.call(reviewer_prompt: original)

      expect(result).to include(original)
    end
  end
end
