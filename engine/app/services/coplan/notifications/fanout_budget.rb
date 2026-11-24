module Coplan
  module Notifications
    # Bounds how much outside delivery one person's comments can start.
    #
    # Every notification sends web push to each of the recipient's devices
    # (up to WebPushSubscription::MAX_PER_USER) and hands it to the delivery
    # adapters (Slack), all on the same job worker as everything else. One
    # person, or an agent posting as them, can write comments far faster than
    # those jobs drain. Inbox rows are always created; once the actor has
    # spent LIMIT deliveries in the current WINDOW, further notifications
    # they cause stay in the inbox only.
    module FanoutBudget
      WINDOW = 10.minutes
      # Far above a person's normal use: a comment mentioning 20 people who
      # each have several devices is still well inside it.
      LIMIT = 300

      module_function

      # Spends `cost` deliveries for `actor_id` and says whether they fit.
      # Work with no actor (review requests) is not budgeted. A cache that
      # stores nothing (the null store) never refuses.
      def spend?(actor_id:, cost:)
        return true if actor_id.blank? || cost <= 0

        window = Time.current.to_i / WINDOW.to_i
        spent = Rails.cache.increment("coplan/notification_fanout/#{actor_id}/#{window}", cost, expires_in: WINDOW * 2)
        return true if spent.nil? || spent <= LIMIT

        Rails.logger.warn("[Coplan] Notification fan-out budget spent for #{actor_id}: inbox only (#{spent} > #{LIMIT} in #{WINDOW.inspect})")
        false
      end
    end
  end
end
