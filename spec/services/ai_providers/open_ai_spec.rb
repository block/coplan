require "rails_helper"

RSpec.describe CoPlan::AiProviders::OpenAi do
  let(:messages) do
    [
      { role: :system, content: "You are a reviewer." },
      { role: :user,   content: "# My Plan\n\nSome content." }
    ]
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("test-key")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("OPENAI_MODEL", described_class::DEFAULT_MODEL).and_return("gpt-4o")
  end

  describe ".call" do
    it "stringifies role symbols and forwards the messages array to the OpenAI client" do
      mock_client = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:chat).and_return({
        "choices" => [{ "message" => { "content" => "Review feedback here." } }]
      })

      result = described_class.call(messages: messages)

      expect(result).to eq("Review feedback here.")
      expect(mock_client).to have_received(:chat).with(
        parameters: {
          model: "gpt-4o",
          messages: [
            { role: "system", content: "You are a reviewer." },
            { role: "user",   content: "# My Plan\n\nSome content." }
          ]
        }
      )
    end

    it "honors an explicit `model:` override" do
      mock_client = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:chat).and_return({
        "choices" => [{ "message" => { "content" => "ok" } }]
      })

      described_class.call(messages: messages, model: "gpt-4o-mini")

      expect(mock_client).to have_received(:chat).with(hash_including(parameters: hash_including(model: "gpt-4o-mini")))
    end

    it "raises an error when response has no content" do
      mock_client = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:chat).and_return({ "choices" => [] })

      expect {
        described_class.call(messages: messages)
      }.to raise_error(CoPlan::AiProviders::OpenAi::Error, "No response content from OpenAI")
    end

    it "raises an error when API key is not configured" do
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
      allow(Rails.application.credentials).to receive(:dig).with(:openai, :api_key).and_return(nil)

      expect {
        described_class.call(messages: messages)
      }.to raise_error(CoPlan::AiProviders::OpenAi::Error, "OpenAI API key not configured")
    end
  end
end
