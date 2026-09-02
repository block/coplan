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

        unless claimed
          # Still waiting out its window: the eventual perform_batch query
          # is "since batch_start" and naturally picks this event up, no
          # action needed. Already running perform_batch, though, means the
          # query may have already executed before this event landed —
          # record it so perform schedules a catch-up run instead of
          # silently dropping it (see the rearm branch in #perform).
          mark_dirty(key, boundary) if running?(key)
          return false
        end

        # Fold in anything a previous run marked dirty but didn't live long
        # enough to rearm for itself (see #perform) — release_debounce
        # deliberately leaves the dirty marker alone so a later claim can
        # still pick it up instead of the event being lost between the two.
        leftover = consume_dirty(key)
        effective_boundary = leftover && leftover < boundary ? leftover : boundary

        Rails.cache.write(debounce_batch_start_cache_key(key), effective_boundary.iso8601(9), expires_in: debounce_state_ttl)
        schedule_run(key, arguments)
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
      # Called for you after `perform_batch` returns with nothing left
      # dirty; the ordering matters, see the comment inside. Deliberately
      # does not touch the dirty marker — see `debounce`'s leftover fold-in.
      def release_debounce(key)
        # Boundary first, claim second. The other order leaves a moment
        # where a new event can win the claim and write its own boundary,
        # only for this call to delete it a line later.
        Rails.cache.delete(debounce_batch_start_cache_key(key))
        Rails.cache.delete(debounce_pending_cache_key(key))
      end

      # True while a job for `key` is actively inside `perform_batch` — a
      # narrower window than the claim itself, which also spans the wait.
      # `debounce` uses this to tell "still waiting, will naturally be
      # picked up" apart from "query may have already run, could be missed".
      def running?(key)
        Rails.cache.exist?(debounce_running_cache_key(key))
      end

      def mark_running(key)
        Rails.cache.write(debounce_running_cache_key(key), true, expires_in: debounce_state_ttl)
      end

      def clear_running(key)
        Rails.cache.delete(debounce_running_cache_key(key))
      end

      # Records that an event arrived while perform_batch was running and
      # may not have made it into that run's query. Keeps the earliest such
      # event so a second and third arrival during the same run don't
      # shadow the first.
      def mark_dirty(key, event_at)
        cache_key = debounce_dirty_cache_key(key)
        current = Rails.cache.read(cache_key)
        earliest = current ? [ Time.zone.parse(current), event_at ].min : event_at
        Rails.cache.write(cache_key, earliest.iso8601(9), expires_in: debounce_state_ttl)
      end

      # Returns and clears the dirty boundary, or nil if nothing arrived
      # mid-run.
      def consume_dirty(key)
        cache_key = debounce_dirty_cache_key(key)
        raw = Rails.cache.read(cache_key)
        return nil unless raw

        Rails.cache.delete(cache_key)
        Time.zone.parse(raw)
      end

      # Re-arms the claim this job already holds for a follow-up run,
      # instead of releasing and re-claiming. Release-then-reclaim would
      # open a gap where an unrelated concurrent `debounce` call could win
      # the fresh claim with its own (later) boundary and skip over the
      # event that's still unhandled here.
      def rearm(key, event_at, arguments)
        Rails.cache.write(debounce_batch_start_cache_key(key), event_at.iso8601(9), expires_in: debounce_state_ttl)
        schedule_run(key, arguments)
      end

      def debounce_pending_cache_key(key)
        "coplan:debounced_job:#{debounce_namespace}:pending:#{key}"
      end

      def debounce_batch_start_cache_key(key)
        "coplan:debounced_job:#{debounce_namespace}:batch_start:#{key}"
      end

      def debounce_running_cache_key(key)
        "coplan:debounced_job:#{debounce_namespace}:running:#{key}"
      end

      def debounce_dirty_cache_key(key)
        "coplan:debounced_job:#{debounce_namespace}:dirty:#{key}"
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

      # Releases the claim if the job never actually made it onto the
      # queue — a raised adapter error, or a halted enqueue callback
      # returning an unsuccessfully-enqueued job — so a stuck claim doesn't
      # block every `debounce` call for this key until debounce_state_ttl
      # expires with no job to show for it.
      def schedule_run(key, arguments)
        job = set(wait: debounce_window).perform_later(key: key, **arguments)
        return true if job&.successfully_enqueued?

        release_debounce(key)
        false
      rescue StandardError
        release_debounce(key)
        raise
      end
    end

    # Including jobs implement `perform_batch`, not `perform` — this owns
    # `perform` so the claim is always released (or rearmed) in the right
    # place.
    def perform(key:, **arguments)
      self.class.mark_running(key)
      perform_batch(key: key, batch_start: debounce_batch_start(key), **arguments)

      # An event that arrived while perform_batch was running may already
      # be too late for the query it just ran — rearm the same claim for a
      # follow-up instead of releasing, so it isn't silently dropped.
      if (dirty_at = self.class.consume_dirty(key))
        self.class.rearm(key, dirty_at, arguments)
      else
        self.class.release_debounce(key)
      end
    ensure
      # Cleared unconditionally, including on a raise from perform_batch
      # (retry_on leaves the claim itself held — see release_debounce not
      # being called above on that path). A retry re-queries batch_start
      # fresh, so it naturally covers anything that arrived in the gap;
      # `running?` only needs to be accurate for the window it's actually
      # protecting.
      self.class.clear_running(key)
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
