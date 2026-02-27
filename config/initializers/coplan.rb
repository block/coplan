CoPlan.configure do |config|
  config.authenticate = ->(request) {
    user_id = request.session[:user_id]
    return nil unless user_id

    user = CoPlan::User.find_by(id: user_id)
    return nil unless user

    {
      external_id: user.external_id,
      name: user.name,
      admin: user.admin?
    }
  }

  config.ai_api_key = Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]
  config.ai_model = "gpt-4o"

  config.notification_handler = ->(event, payload) {
    case event
    when :comment_created
      SlackNotificationJob.perform_later(comment_thread_id: payload[:comment_thread_id])
    end
  }
end
