module CoPlan
  module Notifications
    # Pushes each person's current unread count to their bell badge. One
    # grouped count for the whole set, then one stream per recipient —
    # every path that creates or clears notifications ends here so the
    # badge can never drift from the inbox.
    class BroadcastBadges
      def self.call(user_ids:)
        new(user_ids: user_ids).call
      end

      def initialize(user_ids:)
        @user_ids = Array(user_ids).compact.uniq
      end

      def call
        return if @user_ids.empty?

        counts = Notification.where(user_id: @user_ids).unread.group(:user_id).count
        @user_ids.each do |user_id|
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
