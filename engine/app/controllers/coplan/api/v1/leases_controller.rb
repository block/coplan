module CoPlan
  module Api
    module V1
      class LeasesController < BaseController
        before_action :set_plan
        before_action :authorize_plan_access!

        def create
          lease_token = params[:lease_token] || SecureRandom.hex(32)

          lease = EditLease.acquire!(
            plan: @plan,
            holder_type: ApiToken::HOLDER_TYPE,
            holder_id: api_actor_id,
            lease_token: lease_token
          )

          render json: {
            lease_token: lease_token,
            expires_at: lease.expires_at,
            plan_id: @plan.id
          }, status: :created

        rescue EditLease::Conflict => e
          render json: { error: e.message }, status: :conflict
        end

        def update
          lease = @plan.edit_lease
          unless lease
            render json: { error: "No active lease for this plan" }, status: :not_found
            return
          end

          lease.renew!(lease_token: params[:lease_token])
          render json: {
            lease_token: params[:lease_token],
            expires_at: lease.expires_at,
            plan_id: @plan.id
          }

        rescue EditLease::Conflict => e
          render json: { error: e.message }, status: :conflict
        end

        def destroy
          lease = @plan.edit_lease
          unless lease
            render json: { error: "No active lease for this plan" }, status: :not_found
            return
          end

          lease.release!(lease_token: params[:lease_token])
          head :no_content

        rescue EditLease::Conflict => e
          render json: { error: e.message }, status: :conflict
        end
      end
    end
  end
end
