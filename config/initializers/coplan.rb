CoPlan.configure do |config|
  config.sign_in_path = "/sign_in"

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

  # Optional: delegate user search to an external directory (e.g., People API).
  # When unset, /api/v1/users/search queries the local coplan_users table.
  # config.user_search = ->(query) {
  #   PeopleApi.search(query).map { |p| { id: p.id, name: p.name, email: p.email } }
  # }

  config.notification_handler = ->(event, payload) {
    case event
    when :comment_created
      SlackNotificationJob.perform_later(comment_thread_id: payload[:comment_thread_id])
    end
  }
end
