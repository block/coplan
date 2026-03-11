module CoPlan
  module Api
    module V1
      class BaseController < ActionController::API
        before_action :authenticate_api!

        private

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

        # Unique identifier for the API caller — used as actor_id, holder_id, author_id.
        # With token auth this is the token's ID; with hook auth it's the user's ID.
        def api_actor_id
          @api_token&.id || @current_api_user&.id
        end

        # The type of actor making the API call.
        # Token auth → "local_agent"; hook auth → "human".
        def api_author_type
          @api_token ? ApiToken::HOLDER_TYPE : "human"
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
      end
    end
  end
end
