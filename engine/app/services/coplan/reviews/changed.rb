module CoPlan
  module Reviews
    class Changed
      def self.call(request:, event_type:, actor_token_id: nil, payload: {})
        new(request:, event_type:, actor_token_id:, payload:).call
      end

      def initialize(request:, event_type:, actor_token_id:, payload:)
        @request, @event_type, @actor_token_id, @payload = request, event_type, actor_token_id, payload
      end

      def call
        request, event_type, actor_token_id, payload = @request, @event_type, @actor_token_id, @payload
        AgentEvents::Publish.call(plan: request.plan, event_type: event_type, actor_token_id: actor_token_id,
          payload: { "review_request_id" => request.id, "reviewer_id" => request.reviewer_id }.merge(payload))
        Notifications::BroadcastBadges.call(user_ids: [ request.reviewer_id, request.plan.created_by_user_id ])
        # No viewer-relative HTML or CSRF tokens on a shared stream. Announce
        # removals before replacing comments so late HTTP results cannot put
        # deleted decision labels back while the controls fetch is pending.
        attrs = payload["removed"] ? { "data-removed-review-request-id" => request.id } : {}
        Broadcaster.custom_action_to(request.plan, action: "coplan-review-changed", target: "plan-review-controls", html: "", attrs: attrs)
        if payload["removed"]
          # Public notes survive removal; their deleted review decisions must
          # disappear from the discussion labels in open tabs as well.
          Broadcaster.replace_to(request.plan, target: "plan-general-comment-list", partial: "coplan/plans/general_comment_list",
            locals: { threads: request.plan.comment_threads.with_kept_comments.includes(:comments).order(:created_at) })
        end
      end
    end
  end
end
