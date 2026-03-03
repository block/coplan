module CoPlan
  class Configuration
    attr_accessor :authenticate, :sign_in_path
    attr_accessor :ai_base_url, :ai_api_key, :ai_model
    attr_accessor :error_reporter
    attr_accessor :notification_handler

    def initialize
      @authenticate = nil
      @ai_base_url = "https://api.openai.com/v1"
      @ai_api_key = nil
      @ai_model = "gpt-4o"
      @error_reporter = ->(exception, context) { Rails.error.report(exception, context: context) }
      @notification_handler = nil
    end
  end
end
