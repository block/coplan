module CoPlan
  class Configuration
    attr_accessor :authenticate, :api_authenticate, :sign_in_path
    attr_accessor :ai_base_url, :ai_api_key, :ai_model
    attr_accessor :error_reporter
    attr_accessor :notification_handler
    attr_accessor :onboarding_banner
    attr_accessor :agent_auth_instructions
    attr_accessor :agent_curl_prefix
    attr_accessor :seed_plan_types

    # Path to the partial rendered as the public landing page at "/welcome"
    # (and at "/" for users who haven't created any plans yet). Hosts override
    # this to inject deployment-specific copy, install commands, screenshots,
    # etc. — e.g. coplan-square renders a Square-flavored landing that mentions
    # `sq agents skills add coplan`.
    #
    # The engine ships a generic default at "coplan/welcome/default_landing".
    attr_accessor :landing_page_partial

    # VAPID (Voluntary Application Server Identification) keys for Web Push.
    # Generate once with `bundle exec rails coplan:web_push:generate_keys`.
    # Public key is shared with the browser; private key signs push messages.
    # Subject must be a mailto: or https: URL identifying who runs the server.
    # When any of these are nil, Web Push is disabled and SubscriptionsController
    # returns 503.
    attr_accessor :vapid_public_key, :vapid_private_key, :vapid_subject

    # Lambda for user search used by the /users/search endpoint (typeahead
    # for in-app pickers like @-mentions).
    # Accepts a query string, returns an array of hashes with keys:
    #   :id, :name, :email, :avatar_url, :title, :team
    # When nil (default), falls back to LIKE search on local coplan_users table.
    #
    # Example:
    #   config.user_search = ->(query) {
    #     PeopleApi.search(query).map { |p| { id: p.id, name: p.name, email: p.email } }
    #   }
    attr_accessor :user_search

    def initialize
      @authenticate = nil
      @ai_base_url = "https://api.openai.com/v1"
      @ai_api_key = nil
      @ai_model = "gpt-4o"
      @error_reporter = ->(exception, context) { Rails.error.report(exception, context: context) }
      @notification_handler = nil
      @onboarding_banner = 'Want to upload Agentic plans? Give your agent <a href="/agent-instructions">these instructions</a>.'
      @agent_curl_prefix = 'curl -s -H "Authorization: Bearer $TOKEN"'
      @seed_plan_types = []
      @landing_page_partial = "coplan/welcome/default_landing"
      @agent_auth_instructions = <<~MARKDOWN
        ## Authentication

        Credentials are stored at `~/.config/coplan/credentials.json`:

        ```json
        {
          "base_url": "BASE_URL",
          "token": "your-token-here"
        }
        ```

        On first use:

        1. Read `~/.config/coplan/credentials.json` to get `token` and `base_url`.
        2. If the file does not exist, tell the user: "Go to **Settings → API Tokens** in the CoPlan web UI to create a token." Ask for the token and base URL, then save to `~/.config/coplan/credentials.json` with `chmod 600`.
        3. If any API call returns 401, the token is invalid or revoked. Prompt the user to create a new token in Settings and update the credentials file.

        Use the values from the credentials file in all API calls below.

        All requests use `Authorization: Bearer $TOKEN` header.
      MARKDOWN
    end

    def show_api_tokens?
      true
    end

    def web_push_configured?
      vapid_public_key.present? && vapid_private_key.present? && vapid_subject.present?
    end
  end
end
