module CoPlan
  module Api
    module V1
      # Bootstrap deliberately has no bearer credential yet. Browser approval
      # is a separate, CSRF-protected endpoint using the host's human login.
      class AgentConnectionsController < ActionController::API
        wrap_parameters false
        before_action :require_connection_flow
        before_action :prevent_caching
        rate_limit to: 10, within: 10.minutes, only: :create, name: "connection-start",
          with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }
        rate_limit to: 300, within: 1.minute, only: :token, name: "connection-poll",
          with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }

        def create
          record, device_code, user_code = AgentConnectionRequest.issue!(name: params[:name])
          render json: {
            device_code: device_code, user_code: user_code,
            verification_uri: CoPlan::Engine.routes.url_helpers.agent_connect_url(**url_options),
            verification_uri_complete: CoPlan::Engine.routes.url_helpers.agent_connect_url(**url_options, user_code: user_code),
            expires_in: AgentConnectionRequest::LIFETIME.to_i,
            interval: AgentConnectionRequest::POLL_INTERVAL.to_i
          }, status: :created
        rescue ActiveRecord::RecordInvalid
          render json: { error: "invalid_request", error_description: "Name must be between 1 and 100 characters." }, status: :unprocessable_content
        end

        def token
          code = params[:device_code].to_s
          record = AgentConnectionRequest.find_by(device_code_digest: AgentConnectionRequest.digest(code)) if code.match?(/\A[0-9a-f]{64}\z/)
          result = record ? record.redeem! : { error: "invalid_grant" }
          render json: result, status: result[:error] ? :bad_request : :ok
        end

        private

        def require_connection_flow
          head :not_found unless CoPlan.configuration.agent_connection_enabled?
        end

        def prevent_caching
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"
        end

        def url_options
          { host: request.host, port: request.optional_port, protocol: request.protocol, script_name: request.script_name }
        end
      end
    end
  end
end
