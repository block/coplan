module CoPlan
  # Coalesces a burst of same-key events into a single delayed job.
  #
  # The shape of the problem: something fires an event per occurrence — a
  # comment created, a plan edited — and a host wants one notification for
  # the whole burst instead of one per event. Include this in the host's own
  # ActiveJob class, call `debounce` from the event callback, and implement
  # `perform_batch`; the first event in a window schedules one delayed job
  # and later events inside the window are no-ops. When the job finally runs
  # it is handed the timestamp the batch started at so it can query for
  # everything since.
  #
  #   class DigestJob < ApplicationJob
  #     include CoPlan::DebouncedJob
  #
  #     retry_on Net::OpenTimeout, wait: :polynomially_longer, attempts: 5
  #     debounces_with window: 2.minutes, retry_horizon: 30.minutes
  #
  #     def perform_batch(key:, batch_start:)
  #       comments = CommentThread.find(key).comments.where(created_at: batch_start..)
  #       deliver(comments)
  #     end
  #   end
  #
  #   # in a notification_handler, or a model callback:
  #   DigestJob.debounce(key: comment.comment_thread_id, event_at: comment.created_at)
  #
  # This deliberately knows nothing about comments, threads or delivery
  # channels. It owns exactly three things — the atomic claim, the batch
  # boundary, and when the claim is released — because those are the three
  # things hand-rolled debouncers keep getting wrong.
  #
  # Requires a `Rails.cache` store that honours `unless_exist:` on write
  # (MemoryStore, RedisCacheStore, MemCacheStore, SolidCache all do). A
  # store that ignores it — notably `:null_store`, the Rails default in the
  # test environment — degrades to "every event enqueues its own job".
  module DebouncedJob
    extend ActiveSupport::Concern

    # How long the first event waits for the rest of its burst.
    DEFAULT_WINDOW = 1.minute

    # How far past the scheduled run the claim and the batch boundary must
    # still be readable. This is not the debounce window: it exists to
    # outlive the *job's own retry backoff*, so a job on its last retry
    # still finds the boundary it was enqueued with instead of quietly
    # falling back to a narrower one and dropping the front of its batch.
    # 30 minutes comfortably clears five attempts of `:polynomially_longer`
    # (~6 minutes); jobs with a longer retry policy should raise it.
    DEFAULT_RETRY_HORIZON = 30.minutes

    included do
      class_attribute :debounce_window, instance_writer: false, default: DEFAULT_WINDOW
      class_attribute :debounce_retry_horizon, instance_writer: false, default: DEFAULT_RETRY_HORIZON
    end

    class_methods do
      # Configures the two durations. They are separate on purpose: the
      # window is a product decision ("how long do we wait for the rest of
      # the burst"), the retry horizon is an operational one ("how long can
      # this job still be in flight"). Tying cache TTLs to the window alone
      # is what expires batch state out from under a retrying job.
      def debounces_with(window: nil, retry_horizon: nil)
        self.debounce_window = validate_duration!(window, :window) if window
        self.debounce_retry_horizon = validate_duration!(retry_horizon, :retry_horizon) if retry_horizon
      end

      # TTL for both the claim and the batch boundary. Always longer than
      # the window by the full retry horizon.
      def debounce_state_ttl
        debounce_window + debounce_retry_horizon
      end

      # Claims a pending slot for `key` and, if this caller won it,
      # schedules the one delayed job for the burst. Returns true if this
      # call started a batch, false if a batch was already pending.
      #
      # `event_at` is the triggering event's own timestamp — the record's
      # `created_at`, not `Time.current`. It is required and unforgiving on
      # purpose. `debounce` runs after the event is already persisted (often
      # from a callback or another job), so call time is always *later* than
      # the event; using it as the boundary excludes the very event that
      # started the batch from the batch's own query.
      def debounce(key:, event_at:, **arguments)
        boundary = coerce_event_at(event_at)

        # One atomic write-if-absent is the whole claim. A read-then-write
        # would let two callers both see "no batch pending" and both
        # enqueue, delivering the burst twice.
        claimed = Rails.cache.write(
          debounce_pending_cache_key(key), true,
          expires_in: debounce_state_ttl, unless_exist: true
        )
        return false unless claimed

        Rails.cache.write(debounce_batch_start_cache_key(key), boundary.iso8601(9), expires_in: debounce_state_ttl)
        set(wait: debounce_window).perform_later(key: key, **arguments)
        true
      end

      # The timestamp the batch for `key` started at, or nil if no batch
      # state exists.
      def batch_start_for(key)
        raw = Rails.cache.read(debounce_batch_start_cache_key(key))
        raw && Time.zone.parse(raw)
      end

      def debounce_pending?(key)
        Rails.cache.exist?(debounce_pending_cache_key(key))
      end

      # Ends the batch for `key`, so the next event starts a new one.
      # Called for you after `perform_batch` returns; the ordering matters,
      # see the comment inside.
      def release_debounce(key)
        # Boundary first, claim second. The other order leaves a moment
        # where a new event can win the claim and write its own boundary,
        # only for this call to delete it a line later.
        Rails.cache.delete(debounce_batch_start_cache_key(key))
        Rails.cache.delete(debounce_pending_cache_key(key))
      end

      def debounce_pending_cache_key(key)
        "coplan:debounced_job:#{debounce_namespace}:pending:#{key}"
      end

      def debounce_batch_start_cache_key(key)
        "coplan:debounced_job:#{debounce_namespace}:batch_start:#{key}"
      end

      # Namespaces cache keys per job class, so two debounced jobs keyed on
      # the same record don't fight over one claim.
      def debounce_namespace
        name.presence || to_s
      end

      private

      def coerce_event_at(event_at)
        unless event_at.respond_to?(:to_time)
          raise ArgumentError,
            "#{self}.debounce requires event_at: the triggering event's own timestamp " \
            "(e.g. record.created_at), got #{event_at.inspect}"
        end

        event_at.to_time.utc
      end

      def validate_duration!(value, label)
        unless value.respond_to?(:to_i) && value.to_i.positive?
          raise ArgumentError, "#{self}.debounces_with #{label}: must be a positive duration, got #{value.inspect}"
        end

        value
      end
    end

    # Including jobs implement `perform_batch`, not `perform` — this owns
    # `perform` so the claim is always released in the right place.
    def perform(key:, **arguments)
      perform_batch(key: key, batch_start: debounce_batch_start(key), **arguments)

      # Only after the work is done. Releasing on enqueue, or in an
      # `ensure`, would let an event arriving mid-send (or mid-retry, since
      # a raise skips this line and leaves the claim held) open a second
      # batch that overlaps and clobbers this one.
      self.class.release_debounce(key)
    end

    private

    def debounce_batch_start(key)
      self.class.batch_start_for(key) || missing_batch_start(key)
    end

    # Should not happen: the boundary outlives the window by the whole
    # retry horizon. If it does, the state was lost rather than the batch
    # being empty, so fall back to the widest window we could have retained
    # and say so loudly. Erring wide risks a duplicate; erring narrow drops
    # events silently, which is the failure nobody notices.
    def missing_batch_start(key)
      Rails.logger.warn(
        "#{self.class}: batch start for #{key.inspect} expired before the job ran; " \
        "falling back to #{self.class.debounce_state_ttl.inspect} ago. " \
        "Raise retry_horizon above this job's retry backoff."
      )
      self.class.debounce_state_ttl.ago
    end
  end
end
