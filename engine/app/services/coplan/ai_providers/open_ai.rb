module CoPlan
  module AiProviders
    class OpenAi
      # Used when the host configures neither, so a host that sets only an
      # API key still works.
      DEFAULT_MODEL = "gpt-4o".freeze
      DEFAULT_BASE_URL = "https://api.openai.com/v1".freeze

      # Speech-to-text. Worth a round trip: markedly better than any
      # browser's built-in recognition, and in Safari and Firefox it is
      # the only option there is.
      TRANSCRIBE_MODEL = ENV.fetch("COPLAN_TRANSCRIBE_MODEL", "gpt-4o-transcribe")

      # The prompt biases the decoder toward words it can see in context —
      # jargon, product names, figures from a table. Short on purpose:
      # models cap how much of this they will read.
      MAX_PROMPT_LENGTH = 600

      # Response text can echo prompts, API keys, or uploaded content. Only
      # recognized protocol identifiers are safe to add to logged errors.
      ERROR_TYPES = %w[
        invalid_request_error authentication_error permission_error
        not_found_error rate_limit_error server_error api_error
      ].freeze
      ERROR_CODES = %w[
        context_length_exceeded model_not_found invalid_api_key
        insufficient_quota rate_limit_exceeded invalid_value invalid_type
        missing_required_parameter unsupported_value unsupported_parameter
        content_policy_violation invalid_audio audio_too_short
      ].freeze

      def self.call(system_prompt:, user_content:, model: nil)
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
        raise Error, "Transcription failed: #{e.message}#{failure_detail(e)}"
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
        OpenAI::Client.new(access_token: api_key, uri_base: base_url)
      end

      # Anything speaking the OpenAI wire protocol: Azure OpenAI, LiteLLM,
      # vLLM, Ollama, an internal gateway. The gem appends its own "/v1"
      # only when the base URL doesn't already carry one.
      def self.base_url
        CoPlan.configuration.ai_base_url.presence || DEFAULT_BASE_URL
      end

      def self.api_key
        key = CoPlan.configuration.ai_api_key ||
          Rails.application.credentials.dig(:openai, :api_key) ||
          ENV["OPENAI_API_KEY"]
        raise Error, "OpenAI API key not configured" if key.blank?

        key
      end

      def initialize(system_prompt:, user_content:, model: nil)
        @system_prompt = system_prompt
        @user_content = user_content
        # An explicit argument wins, then the host's configuration. Callers
        # pass a model only when the prompt needs a particular one.
        @model = model.presence || CoPlan.configuration.ai_model.presence || DEFAULT_MODEL
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
      rescue Faraday::Error => e
        raise Error, "Chat request failed: #{e.message}#{self.class.failure_detail(e)}"
      end

      # Keep the reason without copying arbitrary provider text into job logs
      # or transcription responses. Unknown identifiers and free-form messages
      # are omitted, including string-only errors from compatible gateways.
      def self.failure_detail(error)
        response = error.response
        body = response[:body] if response.is_a?(Hash)
        body = JSON.parse(body) if body.is_a?(String)
        detail = body.is_a?(Hash) ? body["error"] : nil
        return "" unless detail.is_a?(Hash)

        parts = []
        parts << detail["type"] if ERROR_TYPES.include?(detail["type"])
        parts << detail["code"] if ERROR_CODES.include?(detail["code"])
        parts.empty? ? "" : " (#{parts.join("/")})"
      rescue JSON::ParserError
        ""
      end

      class Error < StandardError; end
    end
  end
end
