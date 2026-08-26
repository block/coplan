module CoPlan
  class CreateNotificationsJob < ApplicationJob
    queue_as :default

    def perform(comment_thread_id:, actor_id:, comment_id: nil, reason:, actor_api_token_id: nil)
      thread = CommentThread.find(comment_thread_id)
      comment = comment_id ? Comment.find(comment_id) : nil
      Notifications::Create.call(
        comment_thread: thread,
        actor_id: actor_id,
        comment: comment,
        reason: reason,
        actor_api_token_id: actor_api_token_id
      )
    end
  end
end
