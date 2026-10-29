module CoPlan
  class ReviewRequestsController < ApplicationController
    before_action :set_plan
    before_action :set_review_request, only: [ :update, :respond, :compare ]
    rescue_from Reviews::Respond::Conflict, with: :render_conflict
    rescue_from ActiveRecord::RecordInvalid, with: :render_invalid

    def index
      authorize!(@plan, :show?)
      render partial: "coplan/reviews/controls", locals: { plan: @plan }
    end

    def suggestions
      authorize!(@plan, :update?)
      render json: Reviews::Suggest.call(plan: @plan)
    end

    def create
      authorize!(@plan, :update?)
      attributes = params.expect(review_request: [ :reviewer_id, :requirement, :replace_withdrawn ])
      reviewer = User.find(attributes[:reviewer_id])
      request = Reviews::Request.call(plan: @plan, reviewer: reviewer, actor: current_user,
        requirement: attributes[:requirement].presence || "required", create_only: true,
        replace_withdrawn: ActiveModel::Type::Boolean.new.cast(attributes[:replace_withdrawn]))
      render json: Reviews::Serialize.call(request), status: :created
    end

    def update
      authorize!(@plan, :update?)
      attributes = params.expect(review_request: [ :requirement, :request_again ])
      if ActiveModel::Type::Boolean.new.cast(attributes[:request_again])
        Reviews::Request.call(plan: @plan, reviewer: @review_request.reviewer, actor: current_user,
          requirement: attributes[:requirement].presence || @review_request.requirement, request_id: @review_request.id)
      else
        @plan.with_lock { @review_request.reload.update!(requirement: attributes.fetch(:requirement)) }
        Reviews::Changed.call(request: @review_request, event_type: "review.requested",
          payload: { "action" => "requirement_changed", "requirement" => @review_request.requirement })
      end
      render json: Reviews::Serialize.call(@review_request.reload)
    end

    def destroy
      authorize!(@plan, :update?)
      if ActiveModel::Type::Boolean.new.cast(params.dig(:review_request, :remove))
        Reviews::Remove.call(plan: @plan, request_id: params[:id])
      else
        set_review_request
        Reviews::Withdraw.call(request: @review_request, actor: current_user)
      end
      head :no_content
    end

    def respond
      raise NotAuthorizedError unless @review_request.reviewer_id == current_user.id
      attributes = params.expect(review_response: [ :revision, :decision, :note, :idempotency_key ])
      response = Reviews::Respond.call(request: @review_request, actor: current_user,
        revision: attributes[:revision], decision: attributes[:decision], note: attributes[:note], idempotency_key: attributes[:idempotency_key])
      render json: { id: response.id, decision: response.decision, revision: response.plan_version.revision,
                     comment_thread_id: response.comment_thread_id }, status: :created
    end

    def compare
      authorize!(@plan, :show?)
      @approval = @review_request.review_responses.find(params[:response_id])
      @from_version = @approval.plan_version
      @to_version = @plan.current_plan_version
      @diff = Diffy::Diff.new(@from_version.content_markdown, @to_version.content_markdown,
        include_plus_and_minus_in_html: true, context: 3)
      render partial: "coplan/reviews/comparison", locals: { from: @from_version, to: @to_version, diff: @diff }
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    def set_review_request
      @review_request = @plan.review_requests.find(params[:id])
    end

    def render_conflict(error)
      render json: { error: error.message }, status: :conflict
    end

    def render_invalid(error)
      render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_content
    end
  end
end
