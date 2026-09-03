module CoPlan
  class Configuration
    attr_accessor :authenticate, :api_authenticate, :sign_in_path
    # AI provider, used for plan summaries. Any endpoint speaking the
    # OpenAI wire protocol works — Azure OpenAI, LiteLLM, vLLM, Ollama, an
    # internal gateway — by pointing `ai_base_url` at it. With no API key
    # configured the features that need one degrade rather than raise.
    attr_accessor :ai_base_url, :ai_api_key, :ai_model
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

    # Lambda for enriching profile pages from the host's people directory
    # (LDAP, a People API, ...). Receives a CoPlan::User, returns a hash
    # with any of :name, :avatar_url, :title, :team, :profile_url —
    # values present override the local coplan_users columns, and
    # :profile_url adds a "view in directory" link out to the canonical
    # people page. Return nil (or omit keys) to fall back to local data.
    #
    # Called on the request thread when rendering a profile; exceptions
    # are swallowed and reported via `error_reporter`, so a flaky
    # directory degrades to the minimal local profile instead of a 500.
    # Hosts should cache inside the lambda if their directory is slow.
    #
    # Example:
    #   config.directory_profile = ->(user) {
    #     person = PeopleApi.lookup(email: user.email)
    #     {
    #       avatar_url: person.photo_url,
    #       title: person.job_title,
    #       team: person.org_name,
    #       profile_url: person.canonical_url
    #     }
    #   }
    attr_accessor :directory_profile

    # Lambda deciding whether the server may POST wake pings to a given
    # URL. Receives a URI, returns truthy to allow. When nil (default),
    # CoPlan::WakeUrlPolicy applies: the host must resolve entirely to
    # public address space — loopback, RFC1918, link-local (cloud
    # metadata), and friends are refused. Deployments that wake agents on
    # an internal network (or dev, waking localhost) override this:
    #
    #   config.wake_url_policy = ->(uri) { uri.host.end_with?(".internal.example.com") }
    #
    # Checked both when a session registers the URL and again before every
    # POST, because DNS is allowed to change its mind in between.
    attr_accessor :wake_url_policy

    # Library handles a host wants to keep out of user hands, on top of
    # CoPlan::Library::RESERVED_HANDLES. Handles live under /<handle>,
    # so they can't collide with the host's own routes — this is for
    # names the host wants to claim for itself later, or keep off a
    # public namespace.
    #
    # Example:
    #   config.reserved_handles = %w[square block official]
    attr_accessor :reserved_handles


    def initialize
      @authenticate = nil
      @reserved_handles = []
      @ai_base_url = "https://api.openai.com/v1"
      @ai_api_key = nil
      @ai_model = "gpt-4o"
      @error_reporter = ->(exception, context) { Rails.error.report(exception, context: context) }
      @notification_handler = nil
      @track_event = nil
      @onboarding_banner = 'Want to upload Agentic plans? Give your agent <a href="/agent-instructions">these instructions</a>.'
      @agent_curl_prefix = 'curl -s -H "Authorization: Bearer $TOKEN"'
      @seed_plan_types = []
      @wake_url_policy = nil
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
