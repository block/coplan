module CoPlan
  module Comments
    # Parses a comment's body for `[@username](mention:username)` patterns,
    # resolves them against CoPlan::User, and creates a Notification per
    # mentioned user (skipping the author and de-duplicating).
    #
    # Self-mentions and unresolvable usernames are silently dropped — by
    # design, since the chip still renders visually but no inbox row should
    # appear for typos or self-loops.
    class ProcessMentions
      MENTION_PATTERN = CoPlan::MarkdownHelper::MENTION_PATTERN

      def self.call(comment)
        new(comment).call
      end

      def initialize(comment)
        @comment = comment
      end

      def call
        usernames = extract_usernames
        return if usernames.empty?

        mentioned_users = CoPlan::User.where(username: usernames)
        author_user_id = @comment.author_type == "human" ? @comment.author_id : nil
        notified_user_ids = []

        mentioned_users.each do |user|
          next if user.id == author_user_id

          # find_or_create_by to dedupe across edits — if a comment is
          # updated and re-mentions the same user, we don't pile on extra
          # inbox rows.
          notification = Notification.find_or_create_by!(
            user_id: user.id,
            comment_id: @comment.id,
            reason: "mention"
          ) do |n|
            n.plan_id = @comment.comment_thread.plan_id
            n.comment_thread_id = @comment.comment_thread_id
          end
          notified_user_ids << user.id if notification.previously_new_record?
        end

        broadcast_badge_updates(notified_user_ids)
      end

      private

      def extract_usernames
        @comment.body_markdown.to_s.scan(MENTION_PATTERN).flatten.uniq
      end

      def broadcast_badge_updates(user_ids)
        return if user_ids.empty?

        counts = Notification.where(user_id: user_ids).unread.group(:user_id).count
        user_ids.each do |user_id|
          Broadcaster.update_to(
            "coplan_notifications:#{user_id}",
            target: "inbox-badge",
            html: (counts[user_id] || 0).to_s
          )
        end
      end
    end
  end
end
