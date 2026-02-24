module AiProviders
  class Anthropic
    def self.call(system_prompt:, user_content:, model: "claude-sonnet-4-20250514")
      new(system_prompt:, user_content:, model:).call
    end

    def initialize(system_prompt:, user_content:, model:)
      @system_prompt = system_prompt
      @user_content = user_content
      @model = model
    end

    def call
      raise Error, "Anthropic provider not yet implemented. Use OpenAI for now."
    end

    class Error < StandardError; end
  end
end
