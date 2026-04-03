module CoPlan
  class AgentInstructionsController < ApplicationController
    skip_before_action :authenticate_coplan_user!

    def show
      @auth_instructions = CoPlan.configuration.agent_auth_instructions
      @curl = CoPlan.configuration.agent_curl_prefix
      @base = request.base_url
      render layout: false, content_type: "text/markdown", formats: [:text]
    end
  end
end
