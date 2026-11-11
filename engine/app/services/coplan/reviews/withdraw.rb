module CoPlan
  module Reviews
    class Withdraw
      def self.call(request:, actor:, api_token: nil)
        new(request:, actor:, api_token:).call
      end

      def initialize(request:, actor:, api_token:)
        @request, @actor, @api_token = request, actor, api_token
      end

      def call
        request, actor, api_token = @request, @actor, @api_token
        changed = request.plan.with_lock do
          request.reload
          next false if request.status == "withdrawn"

          unless request.plan.plan_events.where(event_type: "review_requested", after_value: request.id).exists?
            RecordRequest.call(request: request)
          end
          request.update!(status: "withdrawn", current_response: nil)
          request.plan.update!(review_sequence: request.plan.review_sequence + 1)
          request.plan.plan_events.create!(event_type: "review_withdrawn", field: "reviews", after_value: request.id,
            actor_id: actor.id, actor_type: api_token ? "local_agent" : "human", api_token: api_token,
            agent_name: api_token && ApiToken.normalized_agent_name(api_token.agent_name.presence || api_token.name),
            metadata: { "reviewer_name" => request.reviewer.name, "revision" => request.plan.current_revision,
                        "requirement" => request.requirement, "generation" => request.generation, "review_sequence" => request.plan.review_sequence })
          request.notifications.unread.where(user_id: request.reviewer_id, reason: "review_requested").update_all(read_at: Time.current)
          true
        end
        if changed
          Changed.call(request: request, event_type: "review.requested", actor_token_id: api_token&.id,
            payload: { "action" => "withdrawn", "withdrawn" => true })
        end
        request
      end
    end
  end
end
