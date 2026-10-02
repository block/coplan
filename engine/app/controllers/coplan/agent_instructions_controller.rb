module CoPlan
  # Serves the agent API instructions at /agent-instructions.
  #
  # This endpoint has two audiences:
  #
  # * **Agents and CLIs** (curl, HTTP libraries, coding agents) fetch it as raw
  #   Markdown. Every API response points here via the `X-Agent-Instructions`
  #   header, so the raw behavior is load-bearing: any client that does not
  #   explicitly ask for HTML continues to get `text/markdown`.
  # * **Humans in a browser** go to the short setup page. They should not have
  #   to read or copy the full API reference themselves.
  #
  # Negotiation is deliberately conservative: we only serve HTML when the
  # Accept header *leads* with `text/html`, which is exactly what every
  # browser sends (`Accept: text/html,application/xhtml+xml,…`) and what
  # Turbo Drive sends on navigation (`Accept: text/html, application/xhtml+xml`).
  # curl's default `Accept: */*`, an absent Accept header, or
  # `Accept: text/markdown` all fall through to raw Markdown. An explicit
  # format always wins over the Accept header: `/agent-instructions.md`
  # forces raw Markdown, while `.html` goes to setup even from curl.
  class AgentInstructionsController < ApplicationController
    skip_before_action :authenticate_coplan_user!

    def show
      return redirect_to(agent_setup_path) if prefers_html?

      prepare_instructions
      render layout: false, content_type: "text/markdown", formats: [ :text ]
    end

    def reference
      prepare_instructions
      @current_coplan_user = CoPlan::Authentication.user_from_request(request)
      CoPlan::Current.user = current_user
      @instructions_markdown = render_to_string(:show, formats: [ :text ], layout: false)
      render :reference
    end

    # Sub-instructions: the library-organizing guide, linked from the main
    # doc and from library API responses. Markdown-only — agents fetch it
    # when an organizing task needs it.
    def organizing
      @auth_instructions = CoPlan.configuration.agent_auth_instructions
      @curl = CoPlan.configuration.agent_curl_prefix
      @base = "#{request.base_url}#{root_path.chomp("/")}"
      render layout: false, content_type: "text/markdown", formats: [ :text ]
    end

    private

    def prepare_instructions
      @auth_instructions = CoPlan.configuration.agent_auth_instructions
      @curl = CoPlan.configuration.agent_curl_prefix
      @request_auth_available = CoPlan.configuration.api_authenticate.present?
      @mint_curl = CoPlan.configuration.agent_mint_curl_prefix.presence ||
        (@request_auth_available ? "curl -s" : @curl)
      # Includes the engine's mount point — host apps may mount CoPlan under
      # a prefix (e.g. /coplan), and request.base_url alone would point every
      # curl example at the wrong path. root_path here is the engine's, which
      # carries the request's SCRIPT_NAME.
      @base = "#{request.base_url}#{root_path.chomp("/")}"
      @plan_types = PlanType.order(:name)
      @create_example_json = create_example_json
    end

    # The Create Plan curl example, with a real configured plan type so
    # agents copy an instance-accurate command. Names are admin-controlled
    # free text, so the payload is JSON-serialized (never hand-interpolated)
    # and single quotes are escaped for the surrounding shell quoting.
    def create_example_json
      example_type = @plan_types.reject { |t| t.name.casecmp?(PlanType::GENERAL_NAME) }.first
      JSON.generate(
        {
          title: "My Plan",
          content: "# My Plan\n\nContent following the type template.",
          plan_type: example_type&.name || "general",
          folder_path: "Team EBT/Q3"
        },
        space: " "
      ).gsub("'", "'\\\\''")
    end

    def prefers_html?
      return true if params[:format] == "html"
      return false if params[:format].present?

      # Intentionally a string check on the raw header rather than
      # `request.format`/`request.accepts`: Rails maps curl's `*/*` to HTML,
      # which would break every agent that follows X-Agent-Instructions here.
      # Requiring the header to lead with text/html matches browsers exactly
      # and nothing else.
      request.headers["Accept"].to_s.strip.start_with?("text/html")
    end
  end
end
