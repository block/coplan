module Coplan
  class BroadcastPermanentCommentDeletionJob < ApplicationJob
    queue_as :default
    self.enqueue_after_transaction_commit = false

    retry_on StandardError, wait: :polynomially_longer, attempts: 5
    retry_on ActiveRecord::RecordNotFound, wait: 1.second, attempts: 5 do |_job, _error|
      Rails.logger.info("Permanent comment deletion broadcast has no audit event; the producer rolled back or the plan was removed.")
    end

    def perform(event_id:, user_ids:)
      event = PlanEvent.find(event_id)
      event.broadcast_history_update
      thread = CommentThread.find_by(id: event.metadata.fetch("thread_id"))
      if thread
        comment = Comment.new(id: event.metadata.fetch("comment_id"))
        target = thread.empty? ? thread : comment
        Broadcaster.remove_to(thread.plan, target: ActionView::RecordIdentifier.dom_id(target))
        Comments::RefreshPreviews.call(thread: thread)
      end
      Notifications::BroadcastBadges.call(user_ids: user_ids)
    end
  end
end
