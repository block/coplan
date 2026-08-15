module CoPlan
  module Api
    module V1
      class BaseController < ActionController::API
        # Disable Rails' wrap_parameters middleware: it auto-wraps the
        # JSON body under the controller's resource name, which collides
        # with body params that share that name (e.g. PUT /content with
        # `{ "content": "..." }` would silently nest the body under
        # params[:content]).
        wrap_parameters false

        before_action :authenticate_api!
        before_action :require_api_token!
        after_action :set_agent_instructions_header

        private

        def set_agent_instructions_header
          response.headers["X-Agent-Instructions"] = CoPlan::Engine.routes.url_helpers.agent_instructions_path
        end

        # Every API call must carry its own Bearer token. The host's
        # request auth (api_authenticate) only proves which human is
        # behind the wire — it says nothing about which agent is acting,
        # and an agent edit that arrives on human credentials gets
        # recorded as a human edit. So hook auth is good for exactly one
        # thing: minting the token (TokensController skips this check for
        # create).
        def require_api_token!
          return if performed?
          return if @api_token

          render json: {
            error: "API calls require a Bearer token. Mint one first: " \
                   "POST #{CoPlan::Engine.routes.url_helpers.api_v1_tokens_path} " \
                   "with {\"agent_name\": \"<your name>\"}, then send " \
                   "Authorization: Bearer <token> on every call."
          }, status: :forbidden
        end

        def authenticate_api!
          token = request.headers["Authorization"]&.delete_prefix("Bearer ")
          if token.present?
            authenticate_via_token!(token)
            return if @api_token
          end

          if CoPlan.configuration.api_authenticate
            attrs = CoPlan.configuration.api_authenticate.call(request)
            if attrs && attrs[:external_id].present?
              provision_user_from_hook!(attrs)
              return
            end
          end

          render json: { error: "Unauthorized" }, status: :unauthorized
        end

        def provision_user_from_hook!(attrs)
          external_id = attrs[:external_id].to_s
          @current_api_user = CoPlan::User.find_or_initialize_by(external_id: external_id)
          @current_api_user.assign_attributes(attrs.slice(:name, :admin, :metadata).compact)
          if @current_api_user.new_record? || @current_api_user.changed?
            @current_api_user.save!
          end
        rescue ActiveRecord::RecordNotUnique
          @current_api_user = CoPlan::User.find_by!(external_id: external_id)
        end

        def authenticate_via_token!(token)
          @api_token = CoPlan::ApiToken.authenticate(token)
        end

        def current_user
          @current_api_user || @api_token&.user
        end

        # Unique identifier for the API caller — the session key for
        # transient ownership (edit sessions, leases, notifications).
        # With token auth this is the token's ID; with hook auth it's the
        # user's ID. NOT for persisted attribution rows — those store the
        # human (api_user_id) so history can name them; see api_agent_name.
        def api_actor_id
          @api_token&.id || @current_api_user&.id
        end

        # The type of actor making the API call.
        # Token auth → "local_agent"; hook auth → "human".
        def api_author_type
          @api_token ? ApiToken::HOLDER_TYPE : "human"
        end

        # Persisted attribution rows (versions, events, comments) store
        # the human behind the token — a token id in actor_id names nobody
        # in a history tab — with agent_name recording which agent acted
        # for them, the same split comments already use.
        def api_user_id
          current_user&.id
        end

        # Which agent to attribute a write to: the caller can say
        # per-request, otherwise the token knows who it was minted for,
        # otherwise the token's own name. Nil under hook auth — a human,
        # not an agent (only reachable where require_api_token! is
        # skipped).
        def api_agent_name
          return nil unless @api_token

          ApiToken.normalized_agent_name(
            params[:agent_name].presence || @api_token.agent_name.presence || @api_token.name
          )
        end

        def set_plan
          @plan = CoPlan::Plan.find_by(id: params[:plan_id] || params[:id])
          unless @plan
            render json: { error: "Plan not found" }, status: :not_found
          end
        end

        def authorize_plan_access!
          return unless @plan
          policy = CoPlan::PlanPolicy.new(current_user, @plan)
          unless policy.show?
            render json: { error: "Plan not found" }, status: :not_found
          end
        end

        def authorize_plan_write!
          return unless @plan
          policy = CoPlan::PlanPolicy.new(current_user, @plan)
          unless policy.update?
            render json: { error: "Not authorized" }, status: :forbidden
          end
        end
      end
    end
  end
end
