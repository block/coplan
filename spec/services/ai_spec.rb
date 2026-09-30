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

    it "uses the model configured for a low-intensity call" do
      allow(CoPlan.configuration).to receive(:ai_models).and_return(low: "gpt-4.1-nano")
      allow(CoPlan::AiProviders::OpenAi).to receive(:call).and_return("summary")

      described_class.call(system_prompt: "sys", user_content: "body", intensity: :low)

      expect(CoPlan::AiProviders::OpenAi).to have_received(:call).with(
        system_prompt: "sys", user_content: "body", model: "gpt-4.1-nano"
      )
    end

    it "falls back to the host model when an intensity has no override" do
      allow(CoPlan.configuration).to receive(:ai_models).and_return({})
      allow(CoPlan::AiProviders::OpenAi).to receive(:call).and_return("summary")

      described_class.call(system_prompt: "sys", user_content: "body", intensity: :low)

      expect(CoPlan::AiProviders::OpenAi).to have_received(:call).with(
        system_prompt: "sys", user_content: "body"
      )
    end

    it "uses the configured medium model when one is provided" do
      allow(CoPlan.configuration).to receive(:ai_models).and_return(medium: "gpt-4o")
      allow(CoPlan::AiProviders::OpenAi).to receive(:call).and_return("comment")

      described_class.call(system_prompt: "sys", user_content: "body", intensity: :medium)

      expect(CoPlan::AiProviders::OpenAi).to have_received(:call).with(
        system_prompt: "sys", user_content: "body", model: "gpt-4o"
      )
    end

    it "rejects an unknown intensity" do
      expect {
        described_class.call(system_prompt: "sys", user_content: "body", intensity: :urgent)
      }.to raise_error(ArgumentError, "Unknown AI intensity: :urgent")
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
