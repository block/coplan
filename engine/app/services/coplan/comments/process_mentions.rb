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

        mentioned_users.each do |user|
          next if user.id == @comment.author_id && @comment.author_type == "human"

          Notification.create!(
            user_id: user.id,
            plan_id: @comment.comment_thread.plan_id,
            comment_thread_id: @comment.comment_thread_id,
            comment_id: @comment.id,
            reason: "mention"
          )
        end

        broadcast_badge_updates(mentioned_users.pluck(:id) - [@comment.author_id])
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
