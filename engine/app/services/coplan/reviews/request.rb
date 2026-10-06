module CoPlan
  module Reviews
    class Request
      def self.call(plan:, reviewer:, actor:, requirement: "required", api_token: nil)
        new(plan:, reviewer:, actor:, requirement:, api_token:).call
      end

      def initialize(plan:, reviewer:, actor:, requirement:, api_token:)
        @plan, @reviewer, @actor, @requirement, @api_token = plan, reviewer, actor, requirement, api_token
      end

      def call
        request = @plan.with_lock do
          request = @plan.review_requests.find_or_initialize_by(reviewer: @reviewer)
          request.assign_attributes(requested_by_user: @actor, requested_plan_version: @plan.current_plan_version,
            requirement: @requirement, status: "pending", requested_at: Time.current)
          request.save!
          # One unread nudge per task. Reading it never completes the task.
          request.notifications.unread.where(user: @reviewer).update_all(read_at: Time.current)
          Notification.create!(plan: @plan, user: @reviewer, review_request: request, reason: "review_requested")
          request
        end
        Changed.call(request: request, event_type: "review.requested", actor_token_id: @api_token&.id)
        request
      end
    end
  end
end
