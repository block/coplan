module CoPlan
  module AiProviders
    class OpenAi
      # Used when the host configures neither, so a host that sets only an
      # API key still works.
      DEFAULT_MODEL = "gpt-4o".freeze
      DEFAULT_BASE_URL = "https://api.openai.com/v1".freeze

      def self.call(system_prompt:, user_content:, model: nil)
        new(system_prompt:, user_content:, model:).call
      end

      def initialize(system_prompt:, user_content:, model: nil)
        @system_prompt = system_prompt
        @user_content = user_content
        # An explicit argument wins, then the host's configuration. Callers
        # pass a model only when the prompt needs a particular one.
        @model = model.presence || CoPlan.configuration.ai_model.presence || DEFAULT_MODEL
      end

      def call
        client = OpenAI::Client.new(access_token: api_key, uri_base: base_url)

        response = client.chat(
          parameters: {
            model: @model,
            messages: [
              { role: "system", content: @system_prompt },
              { role: "user", content: @user_content }
            ]
          }
        )

        content = response.dig("choices", 0, "message", "content")
        raise Error, "No response content from OpenAI" if content.blank?

        content
      end

      private

      # Anything speaking the OpenAI wire protocol: Azure OpenAI, LiteLLM,
      # vLLM, Ollama, an internal gateway. The gem appends its own "/v1"
      # only when the base URL doesn't already carry one.
      def base_url
        CoPlan.configuration.ai_base_url.presence || DEFAULT_BASE_URL
      end

      def api_key
        key = CoPlan.configuration.ai_api_key || Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]
        raise Error, "OpenAI API key not configured" if key.blank?
        key
      end

      class Error < StandardError; end
    end
  end
end
