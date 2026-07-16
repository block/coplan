module CoPlan
  # Serves the agent API instructions at /agent-instructions.
  #
  # This endpoint has two audiences:
  #
  # * **Agents and CLIs** (curl, HTTP libraries, coding agents) fetch it as raw
  #   Markdown. Every API response points here via the `X-Agent-Instructions`
  #   header, so the raw behavior is load-bearing: any client that does not
  #   explicitly ask for HTML gets `text/markdown`, byte-identical to what this
  #   endpoint has always served.
  # * **Humans in a browser** (e.g. clicking the link on the landing page) get
  #   the same instructions rendered as a styled HTML page, with the raw URL
  #   front-and-center so they can hand it to their agent.
  #
  # Negotiation is deliberately conservative: we only serve HTML when the
  # Accept header *leads* with `text/html`, which is exactly what every
  # browser sends (`Accept: text/html,application/xhtml+xml,…`) and what
  # Turbo Drive sends on navigation (`Accept: text/html, application/xhtml+xml`).
  # curl's default `Accept: */*`, an absent Accept header, or
  # `Accept: text/markdown` all fall through to raw Markdown. An explicit
  # `.md` format (`/agent-instructions.md`) always forces raw Markdown so
  # browsers have a way to view the source document too.
  class AgentInstructionsController < ApplicationController
    skip_before_action :authenticate_coplan_user!

    def show
      @auth_instructions = CoPlan.configuration.agent_auth_instructions
      @curl = CoPlan.configuration.agent_curl_prefix
      @base = request.base_url
      @plan_types = PlanType.order(:name)

      if prefers_html?
        @instructions_url = "#{@base}#{coplan.agent_instructions_path}"
        @instructions_markdown = render_to_string(:show, formats: [:text], layout: false)
        render :show, formats: [:html]
      else
        render layout: false, content_type: "text/markdown", formats: [:text]
      end
    end

    private

    def prefers_html?
      return false if params[:format].present? && params[:format] != "html"

      # Intentionally a string check on the raw header rather than
      # `request.format`/`request.accepts`: Rails maps curl's `*/*` to HTML,
      # which would break every agent that follows X-Agent-Instructions here.
      # Requiring the header to lead with text/html matches browsers exactly
      # and nothing else.
      request.headers["Accept"].to_s.strip.start_with?("text/html")
    end
  end
end
