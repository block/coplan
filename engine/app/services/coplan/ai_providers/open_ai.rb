module CoPlan
  module AiProviders
    # Built-in OpenAI plugin for CoPlan.configuration.ai_call.
    #
    # Auto-wired by Configuration when ENV["OPENAI_API_KEY"] is set.
    # Hosts that want a different backend (e.g. Square's Gondola gateway)
    # should override `config.ai_call` in their initializer and ignore
    # this class entirely.
    #
    # API key resolution order: Rails credentials (:openai → :api_key)
    # then ENV["OPENAI_API_KEY"]. Model defaults to gpt-4o; override
    # per-deployment via ENV["OPENAI_MODEL"].
    class OpenAi
      DEFAULT_MODEL = "gpt-4o".freeze

      def self.call(messages:, model: nil)
        new(messages: messages, model: model || ENV.fetch("OPENAI_MODEL", DEFAULT_MODEL)).call
      end

      def initialize(messages:, model:)
        @messages = messages
        @model = model
      end

      def call
        client = OpenAI::Client.new(access_token: api_key)

        response = client.chat(
          parameters: {
            model: @model,
            messages: @messages.map { |m| { role: m[:role].to_s, content: m[:content] } }
          }
        )

        content = response.dig("choices", 0, "message", "content")
        raise Error, "No response content from OpenAI" if content.blank?

        content
      end

      private

      def api_key
        key = Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]
        raise Error, "OpenAI API key not configured" if key.blank?
        key
      end

      class Error < StandardError; end
    end
  end
end
