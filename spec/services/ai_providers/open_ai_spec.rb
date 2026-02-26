require "rails_helper"

RSpec.describe CoPlan::AiProviders::OpenAi do
  let(:model) { "gpt-4o" }
  let(:system_prompt) { "You are a reviewer." }
  let(:user_content) { "# My Plan\n\nSome content." }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("test-key")
  end

  describe ".call" do
    it "returns the AI response content" do
      mock_client = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:chat).and_return({
        "choices" => [{ "message" => { "content" => "Review feedback here." } }]
      })

      result = described_class.call(
        system_prompt: system_prompt,
        user_content: user_content,
        model: model
      )

      expect(result).to eq("Review feedback here.")
      expect(mock_client).to have_received(:chat).with(
        parameters: {
          model: model,
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: user_content }
          ]
        }
      )
    end

    it "raises an error when response has no content" do
      mock_client = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:chat).and_return({ "choices" => [] })

      expect {
        described_class.call(system_prompt: system_prompt, user_content: user_content, model: model)
      }.to raise_error(CoPlan::AiProviders::OpenAi::Error, "No response content from OpenAI")
    end

    it "raises an error when API key is not configured" do
      allow(CoPlan.configuration).to receive(:ai_api_key).and_return(nil)
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
      allow(Rails.application.credentials).to receive(:dig).with(:openai, :api_key).and_return(nil)

      expect {
        described_class.call(system_prompt: system_prompt, user_content: user_content, model: model)
      }.to raise_error(CoPlan::AiProviders::OpenAi::Error, "OpenAI API key not configured")
    end
  end
end
