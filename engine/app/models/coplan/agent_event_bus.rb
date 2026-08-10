module CoPlan
  # Wake/notify plumbing for the agent event inbox, plus the budget that
  # keeps attached agents from eating the whole web server.
  #
  # Two problems this solves, both found by running real agents against
  # the endpoint:
  #
  # 1. **Busy polling.** The inbox endpoints used to re-query the database
  #    every 500ms per connection. Now a waiter blocks on a condition
  #    variable that `AgentEvents::Publish` signals, so an event is
  #    delivered as soon as it's written, with no query in between. The
  #    signal is in-process only, so waiters still wake periodically
  #    (CROSS_PROCESS_INTERVAL) to catch writes from other Puma workers or
  #    background jobs — polling becomes a slow safety net rather than the
  #    delivery mechanism.
  #
  # 2. **Thread starvation.** Every held connection (SSE *or* long-poll)
  #    occupies a Rack thread for its whole life, and RAILS_MAX_THREADS is
  #    small. Without a budget, a handful of attached agents make the app
  #    stop serving pages. `with_slot` caps concurrent held connections and
  #    leaves RESERVED_THREADS free for ordinary requests; callers that
  #    don't get a slot degrade (long-poll answers immediately, SSE is
  #    refused with Retry-After) instead of queueing behind agents.
  class AgentEventBus
    # Threads kept free for ordinary web traffic no matter how many agents
    # are attached.
    RESERVED_THREADS = 2

    # How long a waiter sleeps before re-checking the database anyway, to
    # catch events published by another process.
    CROSS_PROCESS_INTERVAL = 3.0

    class << self
      def instance
        @instance ||= new
      end

      delegate :wait, :signal, :with_slot, :held, :capacity, to: :instance

      # Test seam: drop accumulated state between examples.
      def reset!
        @instance = nil
      end
    end

    def initialize(capacity: nil)
      @capacity = capacity || self.class.default_capacity
      @mutex = Mutex.new
      @conditions = {}
      @waiter_counts = Hash.new(0)
      @held = 0
    end

    def self.default_capacity
      configured = ENV["COPLAN_MAX_AGENT_STREAMS"]
      return configured.to_i.clamp(0, 10_000) if configured.present?

      threads = ENV.fetch("RAILS_MAX_THREADS", 3).to_i
      [threads - RESERVED_THREADS, 1].max
    end

    attr_reader :capacity

    def held
      @mutex.synchronize { @held }
    end

    # Yields true if this connection may hold a thread, false if the
    # server is already at its budget. Always yields — refusing is the
    # caller's decision, since long-poll and SSE degrade differently.
    def with_slot
      granted = @mutex.synchronize do
        if @held < @capacity
          @held += 1
          true
        else
          false
        end
      end

      begin
        yield granted
      ensure
        @mutex.synchronize { @held -= 1 } if granted
      end
    end

    # Block until someone signals this key or `timeout` elapses. Returns
    # after at most CROSS_PROCESS_INTERVAL regardless, so the caller
    # re-checks the database and picks up out-of-process writes.
    def wait(key, timeout:)
      return if timeout <= 0

      slice = [timeout, CROSS_PROCESS_INTERVAL].min
      @mutex.synchronize do
        condition = (@conditions[key] ||= ConditionVariable.new)
        @waiter_counts[key] += 1
        begin
          condition.wait(@mutex, slice)
        ensure
          @waiter_counts[key] -= 1
          if @waiter_counts[key] <= 0
            @waiter_counts.delete(key)
            @conditions.delete(key)
          end
        end
      end
      nil
    end

    def signal(key)
      @mutex.synchronize { @conditions[key]&.broadcast }
    end
  end
end
