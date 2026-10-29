module CoPlan
  module Reviews
    class Changed
      def self.call(request:, event_type:, actor_token_id: nil, payload: {}, broadcast_controls: true)
        new(request:, event_type:, actor_token_id:, payload:, broadcast_controls:).call
      end

      def initialize(request:, event_type:, actor_token_id:, payload:, broadcast_controls:)
        @request, @event_type, @actor_token_id, @payload = request, event_type, actor_token_id, payload
        @broadcast_controls = broadcast_controls
      end

      def call
        request, event_type, actor_token_id, payload = @request, @event_type, @actor_token_id, @payload
        AgentEvents::Publish.call(plan: request.plan, event_type: event_type, actor_token_id: actor_token_id,
          payload: { "review_request_id" => request.id, "reviewer_id" => request.reviewer_id }.merge(payload))
        Notifications::BroadcastBadges.call(user_ids: [ request.reviewer_id, request.plan.created_by_user_id ])
        # No viewer-relative HTML or CSRF tokens on a shared stream. Each
        # open tab fetches its own controls, preserving its current draft.
        Broadcaster.custom_action_to(request.plan, action: "coplan-review-changed", target: "plan-review-controls", html: "") if @broadcast_controls
      end
    end
  end
end
