module CoPlan
  module Reviews
    # A later assignment gets a fresh ID, so old response URLs stay invalid.
    class Remove
      def self.call(plan:, request_id:, actor:, api_token: nil, broadcast: true)
        request = plan.with_lock do
          request = plan.review_requests.current.find_by(id: request_id)
          if request
            unless plan.plan_events.where(event_type: "review_requested", after_value: request.id).exists?
              RecordRequest.call(request: request)
            end
            request.update!(status: "removed")
            request.notifications.unread.where(user: request.reviewer, reason: "review_requested").update_all(read_at: Time.current)
            plan.plan_events.create!(event_type: "review_removed", field: "reviews", after_value: request.id,
              actor_id: actor.id, actor_type: api_token ? "local_agent" : "human", api_token: api_token,
              agent_name: api_token && ApiToken.normalized_agent_name(api_token.agent_name.presence || api_token.name),
              metadata: { "reviewer_name" => request.reviewer.name, "revision" => plan.current_revision,
                          "requirement" => request.requirement })
          end
          request
        end
        Changed.call(request: request, event_type: "review.requested",
          actor_token_id: api_token&.id, payload: { "action" => "removed", "removed" => true }) if request && broadcast
        request
      end
    end
  end
end
