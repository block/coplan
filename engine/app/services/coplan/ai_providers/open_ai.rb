module CoPlan
  module AiProviders
    class OpenAi
      # Speech-to-text. Worth a round trip: markedly better than any
      # browser's built-in recognition, and in Safari and Firefox it is
      # the only option there is.
      TRANSCRIBE_MODEL = ENV.fetch("COPLAN_TRANSCRIBE_MODEL", "gpt-4o-transcribe")

      # The prompt biases the decoder toward words it can see in context —
      # jargon, product names, figures from a table. Short on purpose:
      # models cap how much of this they will read.
      MAX_PROMPT_LENGTH = 600

      def self.call(system_prompt:, user_content:, model: "gpt-4o")
        new(system_prompt:, user_content:, model:).call
      end

      # `file` must respond to #path with a usable extension — the audio
      # format is inferred from the filename, not sniffed from the bytes.
      def self.transcribe(file:, context: nil)
        response = client.audio.transcribe(
          parameters: {
            model: TRANSCRIBE_MODEL,
            file: file,
            prompt: context.presence&.truncate(MAX_PROMPT_LENGTH, omission: "")
          }.compact
        )

        text = response.is_a?(Hash) ? response["text"] : response.to_s
        raise Error, "No transcript returned from OpenAI" if text.blank?

        text.strip
      rescue Faraday::Error => e
        raise Error, "Transcription failed: #{e.message}"
      end

      # Whether server-side calls are possible at all. The voice control
      # asks before choosing how to capture: recording audio with nowhere
      # to send it is worse than not offering to record.
      def self.configured?
        api_key.present?
      rescue Error
        false
      end

      def self.client
        OpenAI::Client.new(access_token: api_key)
      end

      def self.api_key
        key = CoPlan.configuration.ai_api_key ||
          Rails.application.credentials.dig(:openai, :api_key) ||
          ENV["OPENAI_API_KEY"]
        raise Error, "OpenAI API key not configured" if key.blank?

        key
      end

      def initialize(system_prompt:, user_content:, model:)
        @system_prompt = system_prompt
        @user_content = user_content
        @model = model
      end

      def call
        response = self.class.client.chat(
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

      class Error < StandardError; end
    end
  end
end
