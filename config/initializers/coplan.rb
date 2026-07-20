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
      admin: user.admin?,
      username: user.username || user.external_id.to_s.split("@").first.downcase.gsub(/[^a-z0-9._-]/, "").sub(/\A[^a-z0-9]+/, "").presence
    }
  }

  config.ai_api_key = Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]
  config.ai_model = "gpt-4o"

  # Optional: delegate user search to an external directory (e.g., People API).
  # When unset, /api/v1/users/search queries the local coplan_users table.
  # config.user_search = ->(query) {
  #   PeopleApi.search(query).map { |p| { id: p.id, name: p.name, email: p.email } }
  # }

  # Optional: enrich profile pages from the same directory. Values present
  # override local coplan_users columns; :profile_url adds a "view in
  # directory" link out to the canonical people page. Exceptions degrade to
  # the minimal local profile, so a slow/flaky directory can't break pages
  # (cache inside the lambda if lookups are expensive).
  # config.directory_profile = ->(user) {
  #   person = PeopleApi.lookup(email: user.email)
  #   {
  #     avatar_url: person.photo_url,
  #     title: person.job_title,
  #     team: person.org_name,
  #     profile_url: person.canonical_url
  #   }
  # }

  config.notification_handler = ->(event, payload) {
    case event
    when :comment_created
      SlackNotificationJob.perform_later(comment_thread_id: payload[:comment_thread_id])
    end
  }

  # Web Push (VAPID) keys for browser notifications. Always read from ENV (or
  # Rails encrypted credentials in real deployments). When unset, web push is
  # simply disabled (CoPlan.configuration.web_push_configured? returns false
  # and the Settings UI / subscription endpoints stay quiet).
  #
  # Generate fresh keys with:
  #   bundle exec rake coplan:web_push:generate_keys
  config.vapid_public_key  = ENV["COPLAN_VAPID_PUBLIC_KEY"]
  config.vapid_private_key = ENV["COPLAN_VAPID_PRIVATE_KEY"]
  config.vapid_subject     = ENV["COPLAN_VAPID_SUBJECT"]

  # In development only, fall back to a checked-in throwaway keypair so the
  # Settings UI is testable out-of-the-box. Never used outside development —
  # production must set COPLAN_VAPID_* env vars (or wire credentials in).
  if Rails.env.development?
    config.vapid_public_key  ||= "BP7TzhJX7-UzFR0TRI9onFdILyvEto7fpK0NA9aagCXxSCoA4t6RBMD5zaugFetaq6zrxkEGY4ji49T7P7YNrV0="
    config.vapid_private_key ||= "96blWvgu38KWqP3Sa7Uiuohzoz-X32936ZtgIT7e0Tg="
    config.vapid_subject     ||= "mailto:dev@coplan.local"
  end
end
