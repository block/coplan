module Coplan
  module Notifications
    # Best-effort admission budget for initial external delivery jobs. Inbox
    # rows are already committed. Cache loss or failure must not interrupt
    # their creation or the rest of the comment's after-commit callbacks.
    module FanoutBudget
      module_function

      def spend?(actor_id:, cost:)
        limit = Coplan.configuration.notification_fanout_limit
        return true if limit.nil? || actor_id.blank? || cost <= 0

        cache = Rails.cache
        return true if cache.is_a?(ActiveSupport::Cache::NullStore)

        # Lock an existing row, not the cache entry: stores cannot all reserve
        # a missing counter atomically. Release before any delivery is enqueued.
        User.transaction do
          next true unless User.lock.where(id: actor_id).pick(:id)

          # A request-local cache may retain a value from before another
          # worker's spend. Give every reservation a fresh local cache.
          if cache.respond_to?(:with_local_cache)
            cache.with_local_cache { reserve(cache, actor_id, cost, limit) }
          else
            reserve(cache, actor_id, cost, limit)
          end
        end
      rescue StandardError, NotImplementedError => error
        warn_safely("Notification fan-out budget unavailable (#{error.class}); allowing delivery")
        true
      end

      def reserve(cache, actor_id, cost, limit)
        window = Coplan.configuration.notification_fanout_window
        slot = Time.current.to_i / window
        key = "coplan/notification_fanout/v2/#{actor_id}/#{window}/#{slot}"
        spent = cache.read(key) || 0
        if spent + cost > limit
          warn_safely("Notification fan-out budget spent for #{actor_id}: inbox only (#{spent} + #{cost} > #{limit} in #{window}s)")
          return false
        end

        # Rejected work does not consume the remainder. A fixed expiry keeps
        # old windows collectible even when the person continues posting.
        unless cache.write(key, spent + cost, expires_at: Time.at((slot + 2) * window))
          warn_safely("Notification fan-out budget cache write failed; allowing delivery")
        end
        true
      end
      private_class_method :reserve

      def warn_safely(message)
        Rails.logger.warn("[Coplan] #{message}")
      rescue StandardError
        # Logging must not turn an optional delivery budget into a failed comment.
        nil
      end
      private_class_method :warn_safely
    end
  end
end
