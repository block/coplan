module Coplan
  module Comments
    # Soft-deletes a comment and records the event in the plan history feed
    # in a single transaction. Idempotent — calling on an already-deleted
    # comment is a no-op so retries or double-clicks don't write duplicate
    # history entries.
    #
    # Deleting retracts the words: the body becomes Comment::DELETED_BODY,
    # the history event keeps no preview, and agent events already queued
    # for the comment lose their copy of the body.
    class SoftDelete
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
          scrub_agent_events
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
              thread_id: @comment.comment_thread_id
            }
          )
        end

        @comment
      end

      private

      def scrub_agent_events
        AgentEvent.where(comment_id: @comment.id).find_each do |event|
          next unless event.payload.is_a?(Hash) && event.payload.key?("comment_body")

          event.update_columns(payload: event.payload.merge("comment_body" => Comment::DELETED_BODY))
        end
      end
    end
  end
end
