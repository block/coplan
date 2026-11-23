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

      # Our default (and the documented custom URLs) end in /v1, and the
      # gem appends its own api_version segment — but only when the base
      # doesn't already carry one (ruby-openai 8.3.0, http.rb#uri). This
      # exercises the real client's URI construction, no stubs, so a gem
      # upgrade that changes that rule fails here instead of 404ing in
      # production on api.openai.com/v1/v1/chat/completions.
      it "does not let the client double up /v1 on the default base URL" do
        client = OpenAI::Client.new(access_token: "test", uri_base: described_class::DEFAULT_BASE_URL)

        uri = client.send(:uri, path: "/chat/completions")

        expect(uri).to eq("https://api.openai.com/v1/chat/completions")
      end

      it "still gains a /v1 when a custom base leaves it off" do
        client = OpenAI::Client.new(access_token: "test", uri_base: "https://gateway.example.com/openai")

        uri = client.send(:uri, path: "/chat/completions")

        expect(uri).to eq("https://gateway.example.com/openai/v1/chat/completions")
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

    [ Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::ServerError ].each do |error_class|
      it "wraps #{error_class} as a provider error and preserves the cause" do
        failure = error_class.new('503 "Service Unavailable"')
        mock_client = instance_double(OpenAI::Client)
        allow(OpenAI::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat).and_raise(failure)

        expect {
          described_class.call(system_prompt: system_prompt, user_content: user_content)
        }.to raise_error(described_class::Error, 'Chat request failed: 503 "Service Unavailable"') { |error|
          expect(error.cause).to equal(failure)
        }
      end
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

  shared_examples "safe provider diagnostics" do |operation, prefix|
    let(:mock_client) { instance_double(OpenAI::Client) }
    let(:detail) do
      { "error" => { "type" => "invalid_request_error", "code" => "context_length_exceeded",
                     "message" => "Request contained private-plan-content and sk-secret-key" } }
    end
    let(:body) { detail }
    let(:failure) { Faraday::BadRequestError.new("the server responded with status 400", { status: 400, body: body }) }

    before do
      allow(OpenAI::Client).to receive(:new).and_return(mock_client)
      if operation == :chat
        allow(mock_client).to receive(:chat).and_raise(failure)
      else
        audio = double("audio")
        allow(mock_client).to receive(:audio).and_return(audio)
        allow(audio).to receive(:transcribe).and_raise(failure)
      end
    end

    def request
      if operation == :chat
        described_class.call(system_prompt: system_prompt, user_content: user_content)
      else
        described_class.transcribe(file: double("audio file"), context: "private context")
      end
    end

    let(:operation) { operation }

    it "keeps recognized reasons without echoing the provider message" do
      expect { request }.to raise_error(described_class::Error,
        "#{prefix}: the server responded with status 400 (invalid_request_error/context_length_exceeded)") { |error|
          expect(error.cause).to equal(failure)
        }
    end

    context "with a JSON body" do
      let(:body) { detail.to_json }

      it "keeps the same safe identifiers" do
        expect { request }.to raise_error(described_class::Error,
          "#{prefix}: the server responded with status 400 (invalid_request_error/context_length_exceeded)")
      end
    end

    [ nil, "", "<html>Bad gateway</html>", "{broken", "null", "[]", '"error"', [],
      { "error" => "private-plan-content sk-secret-key" }, { "error" => nil }, { "error" => [] },
      { "error" => {} }, { "error" => { "message" => { "prompt" => "private-plan-content" } } },
      { "error" => { "type" => "sk-secret-key", "code" => "private-plan-content" } },
      { "error" => { "type" => "a" * 10_000, "code" => "b" * 10_000 } },
      { "error" => { "type" => [ "invalid_request_error" ], "code" => { "secret" => "value" } } },
      { "error" => { "type" => "invalid_request_error\nforged log line", "code" => false } }
    ].each_with_index do |malformed_body, index|
      context "with an untrusted or unusable error body (#{index})" do
        let(:body) { malformed_body }

        it "falls back to the original status without leaking text or masking the failure" do
          expect { request }.to raise_error(described_class::Error, "#{prefix}: the server responded with status 400") { |error|
            expect(error.cause).to equal(failure)
          }
        end
      end
    end

    it "retains a recognized type when the code is unknown" do
      detail["error"]["code"] = "sk-secret-key"
      expect { request }.to raise_error(described_class::Error,
        "#{prefix}: the server responded with status 400 (invalid_request_error)")
    end

    it "retains a recognized code when the type is unknown" do
      detail["error"]["type"] = "private-plan-content"
      expect { request }.to raise_error(described_class::Error,
        "#{prefix}: the server responded with status 400 (context_length_exceeded)")
    end

    context "when Faraday cannot parse the gateway response" do
      let(:failure) do
        connection = Faraday.new do |faraday|
          faraday.response :raise_error
          faraday.response :json
          faraday.adapter :test do |stub|
            stub.post("/failure") { [ 502, { "Content-Type" => "application/json" }, "<html>Bad gateway</html>" ] }
          end
        end
        begin
          connection.post("/failure")
        rescue Faraday::ParsingError => error
          error
        end
      end

      it "preserves the parsing failure without raising a formatter error" do
        expect(failure.response).to be_a(Faraday::Response)
        expect { request }.to raise_error(described_class::Error, "#{prefix}: #{failure.message}") { |error|
          expect(error.cause).to equal(failure)
        }
      end
    end

    it "handles errors without a response" do
      allow(failure).to receive(:response).and_return(nil)
      expect { request }.to raise_error(described_class::Error, "#{prefix}: the server responded with status 400")
    end
  end

  describe "chat errors" do
    include_examples "safe provider diagnostics", :chat, "Chat request failed"
  end

  describe "transcription errors" do
    include_examples "safe provider diagnostics", :transcribe, "Transcription failed"
  end
end
