require "rails_helper"

RSpec.describe CoPlan::Ai do
  describe ".call" do
    it "delegates to AiProviders::OpenAi and returns its response" do
      allow(CoPlan::AiProviders::OpenAi).to receive(:call).and_return("ai output")

      result = described_class.call(system_prompt: "sys", user_content: "body")

      expect(result).to eq("ai output")
      expect(CoPlan::AiProviders::OpenAi).to have_received(:call).with(
        system_prompt: "sys",
        user_content: "body"
      )
    end

    it "wraps provider errors in CoPlan::Ai::Error so callers don't know the provider" do
      allow(CoPlan::AiProviders::OpenAi).to receive(:call)
        .and_raise(CoPlan::AiProviders::OpenAi::Error, "rate limited")

      expect {
        described_class.call(system_prompt: "sys", user_content: "body")
      }.to raise_error(CoPlan::Ai::Error, "rate limited")
    end
  end
end
