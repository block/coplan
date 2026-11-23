module CoPlan
  class CreateNotificationsJob < ApplicationJob
    queue_as :default

    def perform(comment_thread_id:, actor_id:, comment_id: nil, reason:, actor_api_token_id: nil, excluded_user_ids: [])
      thread = CommentThread.find_by(id: comment_thread_id)
      return unless thread
      comment = comment_id ? thread.comments.find_by(id: comment_id) : nil
      return if comment_id && (comment.nil? || comment.deleted?)
      Notifications::Create.call(
        comment_thread: thread,
        actor_id: actor_id,
        comment: comment,
        reason: reason,
        actor_api_token_id: actor_api_token_id,
        excluded_user_ids: excluded_user_ids
      )
    end
  end
end
