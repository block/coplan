module CoPlan
  module Reviews
    class Request
      def self.call(plan:, reviewer:, actor:, requirement: "required", api_token: nil, create_only: false)
        new(plan:, reviewer:, actor:, requirement:, api_token:, create_only:).call
      end

      def initialize(plan:, reviewer:, actor:, requirement:, api_token:, create_only:)
        @plan, @reviewer, @actor, @requirement, @api_token = plan, reviewer, actor, requirement, api_token
        @create_only = create_only
      end

      def call
        changed = false
        request = @plan.with_lock do
          request = @plan.review_requests.find_or_initialize_by(reviewer: @reviewer)
          # Retrying a create cannot change a decision, reopen a withdrawal,
          # or send another nudge. Only an explicit re-request starts a cycle.
          if @create_only && request.persisted?
            unless ReviewRequest::REQUIREMENTS.include?(@requirement)
              request.errors.add(:requirement, :inclusion)
              raise ActiveRecord::RecordInvalid, request
            end
            next request
          end

          # Preserve the original request for tasks created before request
          # events existed, before its mutable task fields are overwritten.
          if request.persisted? && !@plan.plan_events.where(event_type: "review_requested", after_value: request.id).exists?
            RecordRequest.call(request: request)
          end
          request.assign_attributes(requested_by_user: @actor, requested_plan_version: @plan.current_plan_version,
            requirement: @requirement, status: "pending", requested_at: Time.current,
            generation: request.persisted? ? request.generation + 1 : 1, current_response: nil, reset_reason: request.persisted? ? "requested_again" : nil)
          request.save!
          @plan.update!(review_sequence: @plan.review_sequence + 1)
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
