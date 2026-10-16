module CoPlan
  module Agent
    class ConnectionsController < ApplicationController
      skip_before_action :authenticate_coplan_user!, only: :show
      skip_after_action :track_page_view
      prepend_before_action :require_connection_flow
      before_action :prevent_caching
      rate_limit to: 30, within: 1.minute, name: "connection-verify"

      def show
        @current_coplan_user = CoPlan::Authentication.user_from_request(request)
        CoPlan::Current.user = current_user
        load_request
      end

      def update
        load_request
        if params[:decision] == "approve" && params[:confirm_code] != "1"
          @confirmation_error = "Confirm that the code matches your local agent."
        elsif %w[approve deny].include?(params[:decision])
          @connection&.decide!(user: current_user, approve: params[:decision] == "approve")
        end
        respond_to do |format|
          format.turbo_stream { render :update, status: @confirmation_error ? :unprocessable_content : :ok }
          format.html { render :show, status: @confirmation_error ? :unprocessable_content : :ok }
        end
      end

      private

      def load_request
        @user_code = params[:user_code].to_s.first(20)
        @connection = AgentConnectionRequest.for_user_code(@user_code)
      end

      def require_connection_flow
        head :not_found unless CoPlan.configuration.agent_connection_enabled?
      end

      def prevent_caching
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Content-Security-Policy"] = "frame-ancestors 'none'"
      end
    end
  end
end
