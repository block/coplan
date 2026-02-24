module AiProviders
  class OpenAi
    def self.call(system_prompt:, user_content:, model: "gpt-4o")
      new(system_prompt:, user_content:, model:).call
    end

    def initialize(system_prompt:, user_content:, model:)
      @system_prompt = system_prompt
      @user_content = user_content
      @model = model
    end

    def call
      client = OpenAI::Client.new(access_token: api_key)

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

    def api_key
      key = Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]
      raise Error, "OpenAI API key not configured" if key.blank?
      key
    end

    class Error < StandardError; end
  end
end
