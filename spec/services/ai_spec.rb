require "rails_helper"

RSpec.describe CoPlan::Ai do
  describe ".call" do
    let(:captured) { {} }
    let(:provider_lambda) { ->(messages:) { captured[:messages] = messages; "ai output" } }

    around do |example|
      original = CoPlan.configuration.ai_call
      CoPlan.configuration.ai_call = provider_lambda
      example.run
      CoPlan.configuration.ai_call = original
    end

    it "passes a messages array through to the configured callable" do
      messages = [
        { role: :system, content: "sys" },
        { role: :user, content: "body" }
      ]

      expect(described_class.call(messages: messages)).to eq("ai output")
      expect(captured[:messages]).to eq(messages)
    end

    it "supports the system:/user: convenience sugar" do
      expect(described_class.call(system: "sys", user: "body")).to eq("ai output")
      expect(captured[:messages]).to eq([
        { role: :system, content: "sys" },
        { role: :user,   content: "body" }
      ])
    end

    it "omits role messages whose sugar argument is nil" do
      described_class.call(user: "body only")

      expect(captured[:messages]).to eq([{ role: :user, content: "body only" }])
    end

    it "raises NoProviderError when no callable is configured" do
      CoPlan.configuration.ai_call = nil

      expect {
        described_class.call(system: "sys", user: "body")
      }.to raise_error(CoPlan::Ai::NoProviderError)
    end

    it "wraps provider errors in CoPlan::Ai::Error" do
      CoPlan.configuration.ai_call = ->(messages:) { raise "boom" }

      expect {
        described_class.call(system: "sys", user: "body")
      }.to raise_error(CoPlan::Ai::Error, /boom/)
    end

    it "raises ArgumentError when no messages or sugar are supplied" do
      expect { described_class.call }.to raise_error(ArgumentError, /messages:/)
    end
  end
end
