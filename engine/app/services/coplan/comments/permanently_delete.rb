module CoPlan
  module Comments
    class PermanentlyDelete
      class NotAllowed < StandardError; end

      def self.call(comment:, actor:)
        new(comment:, actor:).call
      end

      def initialize(comment:, actor:)
        @comment = comment
        @actor = actor
      end

      def call
        raise NotAllowed, "Only an admin can permanently delete a comment." unless @actor&.admin?

        thread = @comment.comment_thread
        recipient_ids = @comment.notifications.distinct.pluck(:user_id)
        @comment.with_lock do
          raise NotAllowed, "Soft-delete the comment before permanently deleting it." unless @comment.deleted?
          raise NotAllowed, "This comment belongs to an immutable review receipt and cannot be permanently deleted here." if @comment.review_note?

          AgentEvent.where(comment_id: @comment.id).delete_all
          PlanEvent.where(plan_id: thread.plan_id, event_type: "comment_deleted").find_each do |event|
            next unless event.metadata["comment_id"] == @comment.id

            event.update_columns(metadata: event.metadata.except("body_preview"))
          end
          @comment.destroy!
          event = Plans::LogEvent.call(plan: thread.plan, actor: @actor, event_type: "comment_permanently_deleted",
            metadata: { comment_id: @comment.id, thread_id: thread.id })
          # Enqueue before committing: a queue failure must roll back the deletion.
          # The job retries if a separate queue worker reaches it before commit.
          job = BroadcastPermanentCommentDeletionJob.perform_later(event_id: event.id, user_ids: recipient_ids)
          raise ActiveJob::EnqueueError, "Could not queue the deletion updates." unless job
        end
      end
    end
  end
end
