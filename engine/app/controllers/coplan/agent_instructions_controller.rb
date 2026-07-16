module CoPlan
  class AgentInstructionsController < ApplicationController
    skip_before_action :authenticate_coplan_user!

    def show
      @auth_instructions = CoPlan.configuration.agent_auth_instructions
      @curl = CoPlan.configuration.agent_curl_prefix
      # Includes the engine's mount point — host apps may mount CoPlan under
      # a prefix (e.g. /coplan), and request.base_url alone would point every
      # curl example at the wrong path. root_path here is the engine's, which
      # carries the request's SCRIPT_NAME.
      @base = "#{request.base_url}#{root_path.chomp("/")}"
      @plan_types = PlanType.order(:name)
      render layout: false, content_type: "text/markdown", formats: [:text]
    end
  end
end
