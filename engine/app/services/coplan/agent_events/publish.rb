module CoPlan
  module AgentEvents
    # Fans an event out to the inbox of every agent session on the plan,
    # except the actor's own (an agent should not be woken by its own
    # comment or edit). Suppression matches on the api token id, which is
    # what api_actor_id returns for token-authenticated callers.
    class Publish
      def self.call(plan:, event_type:, actor_id: nil, comment_thread: nil, comment: nil, payload: {})
        new(plan:, event_type:, actor_id:, comment_thread:, comment:, payload:).call
      end

      def initialize(plan:, event_type:, actor_id:, comment_thread:, comment:, payload:)
        @plan = plan
        @event_type = event_type
        @actor_id = actor_id
        @comment_thread = comment_thread
        @comment = comment
        @payload = payload
      end

      def call
        sessions = AgentSession.where(plan_id: @plan.id)
        sessions.each do |session|
          next if @actor_id.present? && session.api_token_id == @actor_id

          AgentEvent.create!(
            api_token_id: session.api_token_id,
            plan_id: @plan.id,
            comment_thread_id: @comment_thread&.id,
            comment_id: @comment&.id,
            event_type: @event_type,
            payload: base_payload.merge(@payload)
          )
          session.wake!
        end
      end

      private

      def base_payload
        payload = {
          "plan_title" => @plan.title,
          "plan_revision" => @plan.current_revision
        }
        if @comment_thread
          payload["thread_status"] = @comment_thread.status
          payload["anchor_text"] = @comment_thread.anchor_text
        end
        if @comment
          payload["comment_body"] = @comment.body_markdown
          payload["comment_author"] = @comment.agent_name.presence || @comment.author&.name
          payload["comment_author_type"] = @comment.author_type
        end
        payload
      end
    end
  end
end
