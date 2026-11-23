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

          AgentEvent.where(comment_id: @comment.id).delete_all
          PlanEvent.where(plan_id: thread.plan_id, event_type: "comment_deleted").find_each do |event|
            next unless event.metadata["comment_id"] == @comment.id

            event.update_columns(metadata: event.metadata.except("body_preview"))
          end
          @comment.destroy!
          Plans::LogEvent.call(plan: thread.plan, actor: @actor, event_type: "comment_permanently_deleted",
            metadata: { comment_id: @comment.id, thread_id: thread.id })
        end

        ActiveRecord.after_all_transactions_commit do
          target = thread.reload.empty? ? thread : @comment
          Broadcaster.remove_to(thread.plan, target: ActionView::RecordIdentifier.dom_id(target))
          RefreshPreviews.call(thread: thread)
          Notifications::BroadcastBadges.call(user_ids: recipient_ids)
        end
      end
    end
  end
end
