module CoPlan
  module Notifications
    # Marks every unread row one person carries for one plan read, and
    # refreshes their badge.
    #
    # Two callers, same meaning — "you've dealt with this plan":
    # opening the plan (you looked; the nudge did its job) and the
    # workspace strip's dismiss (you don't need to look).
    #
    # Rows stay in the inbox history; only their unread flag changes.
    class MarkPlanRead
      def self.call(user:, plan_id:)
        new(user: user, plan_id: plan_id).call
      end

      def initialize(user:, plan_id:)
        @user = user
        @plan_id = plan_id
      end

      # Returns the number of rows cleared. Zero is the common case on a
      # plan visit, and costs one indexed count — no badge broadcast.
      def call
        return 0 if @plan_id.blank?

        unread = @user.notifications.unread.where(plan_id: @plan_id)
        cleared = unread.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        return 0 if cleared.zero?

        BroadcastBadges.call(user_ids: [ @user.id ])
        cleared
      end
    end
  end
end
