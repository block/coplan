module CoPlan
  class Configuration
    attr_accessor :authenticate, :api_authenticate, :sign_in_path
    attr_accessor :error_reporter
    attr_accessor :notification_handler

    # Lambda invoked for every analytics event tracked via
    # `CoPlan::Analytics.track`. Receives (event_name, payload_hash).
    # No-op by default; hosts wire this to write to a destination
    # (MySQL events table, Snowflake, Datadog, etc.).
    #
    # The handler is called inline on the request thread and must not
    # raise — any exception is swallowed and reported via `error_reporter`
    # so a broken sink never breaks user requests. Hosts that need
    # heavyweight writes should enqueue a job from inside the handler.
    #
    # Payload always includes:
    #   :event, :timestamp, :user_id, :properties (Hash)
    #
    # Example:
    #   config.track_event = ->(event, payload) {
    #     AnalyticsEvent.create!(name: event, payload: payload)
    #   }
    attr_accessor :track_event
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

    # Partial used to render the "Built for any AI agent" section of the
    # landing page. This is the single piece of the landing page that hosts
    # most often need to customize: the generic engine partial points users
    # at `/agent-instructions`, while a deployment like coplan-square wants
    # to tell its users to run `sq agents skills add coplan` instead.
    #
    # Swapping just this partial (rather than the whole landing page) lets
    # hosts customize the agents callout without duplicating the hero, the
    # how-it-works steps, or the CSS.
    #
    # The engine ships a generic default at "coplan/welcome/default_agents".
    attr_accessor :landing_agents_partial

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

    # Pluggable AI surface. Invoked by CoPlan::Ai whenever the engine needs
    # a single-shot completion.
    #
    # The callable receives a keyword arg `messages:` (Array of
    # `{role:, content:}` hashes; roles are :system / :user / :assistant)
    # and must return the assistant's text response as a String. Exceptions
    # raised inside the callable are wrapped in CoPlan::Ai::Error so call
    # sites can `discard_on` without knowing the underlying provider.
    #
    # Hosts wire whatever backend they want — a built-in OpenAI plugin
    # (used by default; reads its key from Rails credentials
    # `:openai/:api_key` or `ENV["OPENAI_API_KEY"]`), an internal LLM
    # gateway like Gondola, an Anthropic client, a Bedrock client, a
    # test stub, etc. Model choice and any deployment policy (project
    # routing, rate limits, observability) live inside the callable —
    # not in the engine's API surface.
    #
    # The default lambda is lazy: it dispatches to the OpenAI provider on
    # call, and the provider raises CoPlan::Ai::Error at call time if no
    # key is configured. AI-powered jobs (e.g. SummarizePlanJob) discard
    # cleanly on that error.
    #
    # Example (host initializer):
    #   config.ai_call = ->(messages:) {
    #     GondolaProvider.call(messages: messages, model: "gpt-4o")
    #   }
    attr_accessor :ai_call

    def initialize
      @authenticate = nil
      @error_reporter = ->(exception, context) { Rails.error.report(exception, context: context) }
      @notification_handler = nil
      @track_event = nil
      # Built-in OpenAI default. Always wired so credential-backed
      # deployments work without any explicit boot-time check; the
      # provider itself resolves the API key (Rails credentials → ENV)
      # and raises CoPlan::Ai::Error at call time if nothing is set.
      # Hosts can override this in their initializer to plug in a
      # different backend.
      @ai_call = ->(messages:) { CoPlan::AiProviders::OpenAi.call(messages: messages) }
      @onboarding_banner = 'Want to upload Agentic plans? Give your agent <a href="/agent-instructions">these instructions</a>.'
      @agent_curl_prefix = 'curl -s -H "Authorization: Bearer $TOKEN"'
      @seed_plan_types = []
      @landing_page_partial = "coplan/welcome/default_landing"
      @landing_agents_partial = "coplan/welcome/default_agents"
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
