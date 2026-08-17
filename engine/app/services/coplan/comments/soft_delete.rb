module CoPlan
  module Comments
    # Soft-deletes a comment and records the event in the plan history feed
    # in a single transaction. Idempotent — calling on an already-deleted
    # comment is a no-op so retries or double-clicks don't write duplicate
    # history entries.
    class SoftDelete
      BODY_PREVIEW_LENGTH = 120

      def self.call(**kwargs)
        new(**kwargs).call
      end

      def initialize(comment:, actor:, actor_type: nil, actor_id: nil, agent_name: nil, api_token_id: nil)
        @comment = comment
        @actor = actor
        @actor_type = actor_type
        @actor_id = actor_id
        @agent_name = agent_name
        @api_token_id = api_token_id
      end

      def call
        return @comment if @comment.deleted?

        ActiveRecord::Base.transaction do
          @comment.soft_delete!
          Plans::LogEvent.call(
            plan: @comment.comment_thread.plan,
            actor: @actor,
            actor_type: @actor_type,
            actor_id: @actor_id,
            agent_name: @agent_name,
            api_token_id: @api_token_id,
            event_type: "comment_deleted",
            metadata: {
              comment_id: @comment.id,
              thread_id: @comment.comment_thread_id,
              body_preview: @comment.body_markdown.to_s.truncate(BODY_PREVIEW_LENGTH)
            }
          )
        end

        @comment
      end
    end
  end
end
