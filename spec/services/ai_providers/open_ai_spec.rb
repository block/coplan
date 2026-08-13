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
        "choices" => [ { "message" => { "content" => "Review feedback here." } } ]
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

    # These two were configurable in name only: `ai_model` and
    # `ai_base_url` were documented in the host guide, set in the host's
    # initializer, and read by nothing. The model was hard-coded in this
    # class's signature and the base URL never reached the client at all.
    describe "host configuration" do
      def stub_chat
        mock_client = instance_double(OpenAI::Client)
        allow(OpenAI::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat).and_return({
          "choices" => [ { "message" => { "content" => "ok" } } ]
        })
        mock_client
      end

      it "uses the model the host configured" do
        allow(CoPlan.configuration).to receive(:ai_model).and_return("gpt-4o-mini")
        mock_client = stub_chat

        described_class.call(system_prompt: system_prompt, user_content: user_content)

        expect(mock_client).to have_received(:chat)
          .with(hash_including(parameters: hash_including(model: "gpt-4o-mini")))
      end

      # Callers that need a particular model for a particular prompt still
      # get to say so.
      it "lets an explicit model argument win" do
        allow(CoPlan.configuration).to receive(:ai_model).and_return("gpt-4o-mini")
        mock_client = stub_chat

        described_class.call(system_prompt: system_prompt, user_content: user_content, model: "o3")

        expect(mock_client).to have_received(:chat)
          .with(hash_including(parameters: hash_including(model: "o3")))
      end

      it "falls back to a working default when the host clears the model" do
        allow(CoPlan.configuration).to receive(:ai_model).and_return(nil)
        mock_client = stub_chat

        described_class.call(system_prompt: system_prompt, user_content: user_content)

        expect(mock_client).to have_received(:chat)
          .with(hash_including(parameters: hash_including(model: described_class::DEFAULT_MODEL)))
      end

      # The point of the whole exercise: self-hosting against something
      # that isn't OpenAI.
      it "points the client at the host's base URL" do
        allow(CoPlan.configuration).to receive(:ai_base_url).and_return("http://localhost:11434/v1")
        stub_chat

        described_class.call(system_prompt: system_prompt, user_content: user_content)

        expect(OpenAI::Client).to have_received(:new)
          .with(hash_including(uri_base: "http://localhost:11434/v1"))
      end

      it "falls back to OpenAI when the host clears the base URL" do
        allow(CoPlan.configuration).to receive(:ai_base_url).and_return(nil)
        stub_chat

        described_class.call(system_prompt: system_prompt, user_content: user_content)

        expect(OpenAI::Client).to have_received(:new)
          .with(hash_including(uri_base: described_class::DEFAULT_BASE_URL))
      end
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
