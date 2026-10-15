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
          # Preserve the original request for tasks created before request
          # events existed, before its mutable task fields are overwritten.
          if request.persisted? && !@plan.plan_events.where(event_type: "review_requested", after_value: request.id).exists?
            record_request(request)
          end
          request.assign_attributes(requested_by_user: @actor, requested_plan_version: @plan.current_plan_version,
            requirement: @requirement, status: "pending", requested_at: Time.current)
          request.save!
          record_request(request, api_token: @api_token)
          # One unread nudge per task. Reading it never completes the task.
          request.notifications.unread.where(user: @reviewer).update_all(read_at: Time.current)
          Notification.create!(plan: @plan, user: @reviewer, review_request: request, reason: "review_requested")
          request
        end
        Changed.call(request: request, event_type: "review.requested", actor_token_id: @api_token&.id)
        request
      end

      private

      def record_request(request, api_token: nil)
        @plan.plan_events.create!(event_type: "review_requested", field: "reviews", after_value: request.id,
          actor_id: request.requested_by_user_id, actor_type: api_token ? "local_agent" : "human",
          api_token: api_token, agent_name: api_token && ApiToken.normalized_agent_name(api_token.agent_name.presence || api_token.name),
          created_at: request.requested_at,
          metadata: { "reviewer_name" => request.reviewer.name, "revision" => request.requested_plan_version.revision,
                      "requirement" => request.requirement })
      end
    end
  end
end
