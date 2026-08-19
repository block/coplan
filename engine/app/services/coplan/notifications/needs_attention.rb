module CoPlan
  module Notifications
    # The workspace "Needs attention" strip: plans carrying unread inbox
    # rows for one person, most-unread first. Independent of the active
    # sidebar filters — it's an inbox, not a search result — and bounded to
    # the top LIMIT plans.
    #
    # A query object rather than a controller method because two surfaces
    # render the same strip: the workspace on load, and the "Clear" button
    # on each row, which re-renders it (clearing one plan can promote the
    # next one into view).
    class NeedsAttention
      LIMIT = 5

      Result = Struct.new(:unread_counts, :plans, :notification_ids, keyword_init: true) do
        def any?
          plans.present?
        end

        # Plans with unread rows that didn't fit in the strip.
        def remaining
          unread_counts.size - plans.size
        end

        def unread_count_for(plan)
          unread_counts[plan.id].to_i
        end

        def notification_id_for(plan)
          notification_ids.fetch(plan.id)
        end
      end

      def self.call(user:)
        new(user: user).call
      end

      def initialize(user:)
        @user = user
      end

      def call
        unread_counts = @user.notifications.unread.group(:plan_id).count
        top_ids = unread_counts.sort_by { |_id, count| -count }.first(LIMIT).map(&:first)

        # The plan view hides resolved threads by default. Route each row
        # through an unread notification so the destination marks it read
        # and deep-links to the exact thread. Bounded to LIMIT indexed
        # lookups.
        # compact: another tab (or the Clear button) can empty a plan
        # between the count and this lookup — drop the row rather than
        # render a link to a notification that no longer exists.
        notification_ids = top_ids.index_with do |plan_id|
          @user.notifications.unread.where(plan_id: plan_id).newest_first.pick(:id)
        end.compact

        # Even an inbox routes through the discovery predicate — a stale
        # notification must not resurface an archived plan or another
        # user's unlisted draft.
        plans = Plan.visible_to(@user).active.where(id: notification_ids.keys)
          .sort_by { |plan| -unread_counts.fetch(plan.id, 0) }

        Result.new(unread_counts: unread_counts, plans: plans, notification_ids: notification_ids)
      end
    end
  end
end
