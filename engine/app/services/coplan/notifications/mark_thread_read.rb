module CoPlan
  module Notifications
    # Marks every unread inbox row for one thread read and refreshes the
    # badge for whoever was carrying them.
    #
    # Called when a thread closes (resolved/discarded). A closed thread is
    # finished work: its highlight is hidden in the doc view, so a row
    # pointing at it sends the reader to a page with nothing on it. The
    # rows stay in the inbox history — they just stop counting as unread.
    class MarkThreadRead
      def self.call(comment_thread:)
        new(comment_thread: comment_thread).call
      end

      def initialize(comment_thread:)
        @comment_thread = comment_thread
      end

      # Returns the number of rows cleared.
      def call
        unread = Notification.unread.where(comment_thread_id: @comment_thread.id)
        user_ids = unread.distinct.pluck(:user_id)
        return 0 if user_ids.empty?

        cleared = unread.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        BroadcastBadges.call(user_ids: user_ids)
        cleared
      end
    end
  end
end
