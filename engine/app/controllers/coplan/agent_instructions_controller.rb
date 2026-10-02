module CoPlan
  # Serves the agent instructions: a short primer at /agent-instructions,
  # plus topic guides at /agent-instructions/<guide> that agents fetch only
  # when a task needs them. The split keeps every agent's first read small —
  # most never need the live-session protocol or the slide-deck rules.
  #
  # Every page has two audiences:
  #
  # * **Agents and CLIs** (curl, HTTP libraries, coding agents) fetch it as raw
  #   Markdown. Every API response points at the primer via the
  #   `X-Agent-Instructions` header, so the raw behavior is load-bearing: any
  #   client that does not explicitly ask for HTML gets `text/markdown`.
  # * **Humans in a browser** (e.g. clicking the link on the landing page) get
  #   the same instructions rendered as a styled HTML page. The primer puts
  #   the raw URL front-and-center so they can hand it to their agent.
  #
  # Negotiation is deliberately conservative: we only serve HTML when the
  # Accept header *leads* with `text/html`, which is exactly what every
  # browser sends (`Accept: text/html,application/xhtml+xml,…`) and what
  # Turbo Drive sends on navigation (`Accept: text/html, application/xhtml+xml`).
  # curl's default `Accept: */*`, an absent Accept header, or
  # `Accept: text/markdown` all fall through to raw Markdown. An explicit
  # format always wins over the Accept header: `.md` forces raw Markdown (so
  # browsers can view the source document) and `.html` forces the rendered
  # page.
  class AgentInstructionsController < ApplicationController
    skip_before_action :authenticate_coplan_user!
    before_action :set_template_values

    # URL segment => template under agent_instructions/guides/. The primer
    # links every entry; a spec holds it to that.
    GUIDES = {
      "markdown" => "markdown",
      "presentations" => "presentations",
      "creating" => "creating",
      "editing" => "editing",
      "comments" => "comments",
      "live" => "live",
      "live/claude-code" => "live_claude_code",
      "live/amp" => "live_amp",
      "live/codex" => "live_codex",
      "live/hosted" => "live_hosted",
      "live/bridge" => "live_bridge",
      "organizing" => "organizing",
      "api" => "api"
    }.freeze

    def show
      @auth_instructions = CoPlan.configuration.agent_auth_instructions
      @create_example_json = create_example_json
      render_instructions(:show, url: coplan.agent_instructions_url, raw_path: agent_instructions_path(format: :md))
    end

    def guide
      template = GUIDES[params[:guide].to_s]
      unless template
        return render plain: "# Unknown guide\n\nThe guide list is at #{@base}/agent-instructions\n",
          status: :not_found, content_type: "text/markdown"
      end

      render_instructions("coplan/agent_instructions/guides/#{template}",
        url: coplan.agent_instructions_guide_url(guide: params[:guide]),
        raw_path: coplan.agent_instructions_guide_path(guide: params[:guide], format: :md),
        html_template: :guide)
    end

    private

    def set_template_values
      @curl = CoPlan.configuration.agent_curl_prefix
      # Includes the engine's mount point — host apps may mount CoPlan under
      # a prefix (e.g. /coplan), and request.base_url alone would point every
      # curl example at the wrong path. root_path here is the engine's, which
      # carries the request's SCRIPT_NAME.
      @base = "#{request.base_url}#{root_path.chomp("/")}"
      @plan_types = PlanType.order(:name)
    end

    def render_instructions(template, url:, raw_path:, html_template: template)
      if prefers_html?
        # The pages are public, but signed-in visitors should still see their
        # normal nav chrome (search, inbox, sign-out) in the shared layout —
        # same optional-resolve approach as WelcomeController.
        @current_coplan_user = CoPlan::Authentication.user_from_request(request)
        CoPlan::Current.user = current_user

        @instructions_url = url
        @raw_path = raw_path
        @instructions_markdown = render_to_string(template, formats: [ :text ], layout: false)
        render html_template, formats: [ :html ]
      else
        render template, layout: false, content_type: "text/markdown", formats: [ :text ]
      end
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
