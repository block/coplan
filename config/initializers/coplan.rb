CoPlan.configure do |config|
  config.user_class = "User"

  config.ai_api_key = Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]
  config.ai_model = "gpt-4o"

  config.notification_handler = ->(event, payload) {
    case event
    when :comment_created
      SlackNotificationJob.perform_later(comment_thread_id: payload[:comment_thread_id])
    end
  }
end
