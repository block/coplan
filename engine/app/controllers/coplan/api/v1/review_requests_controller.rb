module CoPlan
  module Api
    module V1
      class ReviewRequestsController < BaseController
        before_action :set_plan
        before_action :authorize_plan_access!
        before_action :authorize_plan_write!, only: [ :create, :update, :destroy ]
        before_action :set_review_request, only: [ :update, :destroy, :respond ]
        rescue_from Reviews::Respond::Conflict do |error|
          render json: { error: error.message, code: error.code }, status: :conflict
        end
        rescue_from ActiveRecord::RecordInvalid do |error|
          render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_content
        end
        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "Review request or reviewer not found" }, status: :not_found
        end

        def index
          requests = @plan.review_requests.includes(:reviewer, :requested_plan_version, review_responses: :plan_version)
          render json: { review_requests: requests.map { |request| Reviews::Serialize.call(request) },
                         approval_meaning: "Satisfied with a specific version; grants no execution authority or permissions." }
        end

        def create
          request = Reviews::Request.call(plan: @plan, reviewer: User.find(params.require(:reviewer_id)), actor: current_user,
            requirement: params[:requirement].presence || "required", api_token: @api_token)
          render json: Reviews::Serialize.call(request), status: :created
        end

        def update
          if ActiveModel::Type::Boolean.new.cast(params[:request_again])
            Reviews::Request.call(plan: @plan, reviewer: @review_request.reviewer, actor: current_user,
              requirement: params[:requirement].presence || @review_request.requirement, api_token: @api_token)
          else
            @plan.with_lock { @review_request.update!(requirement: params.require(:requirement)) }
            Reviews::Changed.call(request: @review_request, event_type: "review.requested", actor_token_id: api_token_id)
          end
          render json: Reviews::Serialize.call(@review_request.reload)
        end

        def destroy
          @plan.with_lock do
            @review_request.update!(status: "withdrawn")
            @review_request.notifications.unread.update_all(read_at: Time.current)
          end
          Reviews::Changed.call(request: @review_request, event_type: "review.requested", actor_token_id: api_token_id,
            payload: { "withdrawn" => true })
          head :no_content
        end

        def respond
          unless @review_request.reviewer_id == current_user.id
            return render json: { error: "Only the requested reviewer can respond" }, status: :forbidden
          end
          response = Reviews::Respond.call(request: @review_request, actor: current_user,
            revision: params.require(:revision), decision: params.require(:decision), note: params[:note], api_token: @api_token, idempotency_key: params[:idempotency_key])
          render json: { id: response.id, decision: response.decision, revision: response.plan_version.revision,
                         actor_type: response.actor_type, agent_name: response.agent_name,
                         comment_thread_id: response.comment_thread_id }, status: :created
        end

        private

        def set_review_request
          @review_request = @plan.review_requests.find(params[:id])
        end
      end
    end
  end
end
