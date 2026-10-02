module CoPlan
  module Agent
    class SetupController < ApplicationController
      skip_before_action :authenticate_coplan_user!

      def show
        @setup_url = coplan.agent_setup_url(format: :md)
        @instructions_url = coplan.agent_instructions_url
        @install_command = CoPlan.configuration.agent_setup_install_command

        if prefers_html?
          @current_coplan_user = CoPlan::Authentication.user_from_request(request)
          CoPlan::Current.user = current_user
          render :show, formats: [ :html ]
        else
          render layout: false, content_type: "text/markdown", formats: [ :text ]
        end
      end

      private

      def prefers_html?
        return true if params[:format] == "html"
        return false if params[:format].present?

        request.headers["Accept"].to_s.strip.start_with?("text/html")
      end
    end
  end
end
