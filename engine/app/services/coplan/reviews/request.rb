module CoPlan
  module Reviews
    class Request
      def self.call(plan:, reviewer:, actor:, requirement: "required", api_token: nil, create_only: false, request_id: nil, replace_withdrawn: false)
        new(plan:, reviewer:, actor:, requirement:, api_token:, create_only:, request_id:, replace_withdrawn:).call
      end

      def initialize(plan:, reviewer:, actor:, requirement:, api_token:, create_only:, request_id:, replace_withdrawn:)
        @plan, @reviewer, @actor, @requirement, @api_token = plan, reviewer, actor, requirement, api_token
        @create_only = create_only
        @request_id = request_id
        @replace_withdrawn = replace_withdrawn
      end

      def call
        changed = false
        request = @plan.with_lock do
          request = if @request_id
            @plan.review_requests.where(reviewer: @reviewer).find(@request_id)
          else
            @plan.review_requests.find_or_initialize_by(reviewer: @reviewer)
          end
          # API create retries preserve every existing task. The web add form
          # deliberately replaces withdrawn tasks left by earlier removals.
          if @create_only && request.persisted?
            unless ReviewRequest::REQUIREMENTS.include?(@requirement)
              request.errors.add(:requirement, :inclusion)
              raise ActiveRecord::RecordInvalid, request
            end
            next request unless @replace_withdrawn && request.status == "withdrawn"

            request.destroy!
            request = @plan.review_requests.new(reviewer: @reviewer)
          end

          # Preserve the original request for tasks created before request
          # events existed, before its mutable task fields are overwritten.
          if request.persisted? && !@plan.plan_events.where(event_type: "review_requested", after_value: request.id).exists?
            RecordRequest.call(request: request)
          end
          request.assign_attributes(requested_by_user: @actor, requested_plan_version: @plan.current_plan_version,
            requirement: @requirement, status: "pending", requested_at: Time.current)
          request.save!
          RecordRequest.call(request: request, api_token: @api_token)
          # One unread nudge per task. Reading it never completes the task.
          request.notifications.unread.where(user: @reviewer).update_all(read_at: Time.current)
          Notification.create!(plan: @plan, user: @reviewer, review_request: request, reason: "review_requested")
          changed = true
          request
        end
        Changed.call(request: request, event_type: "review.requested", actor_token_id: @api_token&.id,
          payload: { "action" => "requested", "requirement" => request.requirement }) if changed
        request
      end
    end
  end
end
