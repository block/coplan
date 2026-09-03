module CoPlan
  # Serves the agent-side scripts (attach, bridge, and the session helper
  # they share) so a new agent's first encounter needs nothing but curl —
  # no repo checkout, no gem, no install step. The setup section of
  # /agent-instructions points here.
  #
  # Public for the same reason /agent-instructions is: this is the front
  # door, and the scripts themselves are not secrets — every credential
  # they use arrives via environment variables at run time.
  class AgentToolsController < ApplicationController
    skip_before_action :authenticate_coplan_user!

    TOOLS_DIR = CoPlan::Engine.root.join("agent_tools")

    # Whitelist rather than glob: params must never pick a path.
    TOOLS = %w[coplan-attach coplan-bridge coplan_session.rb].freeze

    def show
      return head :not_found unless TOOLS.include?(params[:tool])

      # Rendered inline rather than send_file for the same reason as the
      # service worker: the file lives inside the gem, where a reverse
      # proxy intercepting X-Sendfile can't reach it.
      render plain: TOOLS_DIR.join(params[:tool]).read, content_type: "text/plain"
    end
  end
end
