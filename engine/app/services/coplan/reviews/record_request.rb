module CoPlan
  module Reviews
    class RecordRequest
      def self.call(request:, api_token: nil)
        new(request:, api_token:).call
      end

      def initialize(request:, api_token:)
        @request, @api_token = request, api_token
      end

      def call
        request, api_token = @request, @api_token
        request.plan.plan_events.create!(event_type: "review_requested", field: "reviews", after_value: request.id,
          actor_id: request.requested_by_user_id, actor_type: api_token ? "local_agent" : "human",
          api_token: api_token, agent_name: api_token && ApiToken.normalized_agent_name(api_token.agent_name.presence || api_token.name),
          created_at: request.requested_at,
          metadata: { "reviewer_name" => request.reviewer.name, "revision" => request.requested_plan_version.revision,
                      "requirement" => request.requirement })
      end
    end
  end
end
