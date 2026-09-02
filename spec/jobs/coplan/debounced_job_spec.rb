require "rails_helper"

# A transient failure, so the test job can exercise its own retry policy.
class DebouncedJobSpecError < StandardError; end

# Stand-in for a host's job. Deliberately touches nothing but the concern:
# the primitive is supposed to know nothing about comments or delivery.
class DebouncedJobSpecJob < CoPlan::ApplicationJob
  include CoPlan::DebouncedJob

  retry_on DebouncedJobSpecError, wait: 5.minutes, attempts: 3

  debounces_with window: 2.minutes, retry_horizon: 30.minutes

  cattr_accessor :batches, default: []
  cattr_accessor :failures_remaining, default: 0

  def perform_batch(key:, batch_start:)
    if self.class.failures_remaining.positive?
      self.class.failures_remaining -= 1
      raise DebouncedJobSpecError, "transient"
    end

    self.class.batches << { key: key, batch_start: batch_start, performed_at: Time.current }
  end
end

RSpec.describe CoPlan::DebouncedJob, type: :job do
  include ActiveJob::TestHelper

  let(:job) { DebouncedJobSpecJob }
  let(:key) { "thread-abc" }

  # The test environment runs :null_store, which silently ignores
  # `unless_exist:` — swap in a real store so claims actually claim.
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_cache
  end

  before do
    DebouncedJobSpecJob.batches = []
    DebouncedJobSpecJob.failures_remaining = 0
  end

  describe "the batch boundary" do
    # Failure mode 1: using claim time as the boundary. `debounce` always
    # runs after the triggering event is persisted, so Time.current is
    # later than the event's created_at and the batch's own query excludes
    # the event that started it.
    it "records the triggering event's timestamp, not the time debounce was called" do
      freeze_time do
        event_at = 90.seconds.ago

        expect(job.debounce(key: key, event_at: event_at)).to be(true)

        expect(job.batch_start_for(key)).to eq(event_at)
        expect(job.batch_start_for(key)).to be < Time.current
      end
    end

    it "hands that same timestamp to perform_batch, so the triggering event is inside its own batch" do
      freeze_time do
        event_at = 90.seconds.ago
        job.debounce(key: key, event_at: event_at)

        travel 2.minutes
        job.perform_now(key: key)

        batch = DebouncedJobSpecJob.batches.sole
        expect(batch[:batch_start]).to eq(event_at)
        expect(batch[:batch_start]).to be < batch[:performed_at]
      end
    end

    it "refuses to guess a boundary when event_at is missing" do
      expect { job.debounce(key: key, event_at: nil) }
        .to raise_error(ArgumentError, /triggering event's own timestamp/)
      expect(enqueued_jobs).to be_empty
    end

    it "keeps the first event's boundary when later events land inside the window" do
      freeze_time do
        first_at = 10.seconds.ago
        job.debounce(key: key, event_at: first_at)

        travel 30.seconds
        expect(job.debounce(key: key, event_at: Time.current)).to be(false)

        expect(job.batch_start_for(key)).to eq(first_at)
      end
    end
  end

  # Failure mode 2: a read-then-write claim. Two workers both read "no batch
  # pending", both write, both enqueue — the burst is delivered twice. The
  # threaded example below is the end-to-end assertion; the two after it pin
  # the structure, since MRI rarely interleaves a read-then-write on demand.
  describe "claiming the batch" do
    it "lets exactly one of many concurrent callers win the claim" do
      event_at = 1.minute.ago
      results = []
      mutex = Mutex.new
      start_gate = Queue.new

      threads = 25.times.map do
        Thread.new do
          start_gate.pop # all 25 launch together, into the same claim
          won = job.debounce(key: key, event_at: event_at)
          mutex.synchronize { results << won }
        end
      end
      25.times { start_gate << :go }
      threads.each(&:join)

      expect(results.count(true)).to eq(1)
      expect(results.size).to eq(25)
      expect(enqueued_jobs.count { |j| j["job_class"] == "DebouncedJobSpecJob" }).to eq(1)
    end

    it "claims with a write-if-absent and never reads the pending key to decide" do
      allow(Rails.cache).to receive(:read).and_call_original
      allow(Rails.cache).to receive(:write).and_call_original

      job.debounce(key: key, event_at: 1.minute.ago)

      # The claim itself never reads: the atomic write's return value is the
      # only input. (A read of the *dirty* key does happen here, to fold in
      # anything left over from a previous run — see "leftover dirty state"
      # below — but that's unrelated to who wins the claim.)
      expect(Rails.cache).not_to have_received(:read).with(job.debounce_pending_cache_key(key))
      expect(Rails.cache).to have_received(:write).with(
        job.debounce_pending_cache_key(key), true, hash_including(unless_exist: true)
      ).once
    end

    # The atomic write's return value is the only thing that decides who
    # owns the batch. A read-then-write claim would look at the empty cache
    # here, conclude it had won, and enqueue a duplicate.
    it "loses the claim purely on the write's return value, not on cache contents" do
      pending_key = job.debounce_pending_cache_key(key)
      allow(Rails.cache).to receive(:write).and_call_original
      allow(Rails.cache).to receive(:write)
        .with(pending_key, true, hash_including(unless_exist: true)).and_return(false)

      expect(Rails.cache.read(pending_key)).to be_nil
      expect(job.debounce(key: key, event_at: 1.minute.ago)).to be(false)

      expect(enqueued_jobs).to be_empty
      expect(job.batch_start_for(key)).to be_nil
    end

    it "enqueues one delayed job for the burst and no-ops for the rest" do
      freeze_time do
        expect {
          job.debounce(key: key, event_at: Time.current)
        }.to have_enqueued_job(DebouncedJobSpecJob).with(key: key).at(2.minutes.from_now)

        expect {
          3.times { job.debounce(key: key, event_at: Time.current) }
        }.not_to have_enqueued_job(DebouncedJobSpecJob)
      end
    end

    it "keys claims per job class and per key" do
      job.debounce(key: "one", event_at: 1.minute.ago)

      expect(job.debounce_pending?("one")).to be(true)
      expect(job.debounce_pending?("two")).to be(false)
      expect(job.debounce_pending_cache_key("one")).to include("DebouncedJobSpecJob")
    end
  end

  describe "state lifetime" do
    # Failure mode 3: TTLs tied to the debounce window. A job that retries
    # for minutes finds its batch state already gone and silently narrows
    # its query, dropping the front of the batch.
    it "sizes state TTL as the window plus the full retry horizon" do
      expect(job.debounce_state_ttl).to eq(32.minutes)
      expect(job.debounce_state_ttl).to be > job.debounce_window
      expect(job.debounce_state_ttl).to be > job.debounce_retry_horizon
    end

    it "keeps the boundary and the claim readable long past the debounce window" do
      freeze_time do
        event_at = Time.current
        job.debounce(key: key, event_at: event_at)

        travel 20.minutes # far past the 2-minute window, inside the retry horizon

        expect(job.batch_start_for(key)).to eq(event_at)
        expect(job.debounce_pending?(key)).to be(true)
      end
    end

    it "holds the claim across a retry and gives the retry the original boundary" do
      freeze_time do
        event_at = 30.seconds.ago
        job.debounce(key: key, event_at: event_at)
        DebouncedJobSpecJob.failures_remaining = 1

        travel 2.minutes
        job.perform_now(key: key) # raises inside perform_batch, retry_on re-enqueues

        expect(DebouncedJobSpecJob.batches).to be_empty
        expect(job.debounce_pending?(key)).to be(true)

        travel 20.minutes # the retry finally runs, way past the window
        job.perform_now(key: key)

        expect(DebouncedJobSpecJob.batches.sole[:batch_start]).to eq(event_at)
      end
    end

    it "warns and falls back to the widest retained window if state is somehow lost" do
      freeze_time do
        job.debounce(key: key, event_at: Time.current)

        travel 33.minutes # past state TTL entirely
        expect(job.batch_start_for(key)).to be_nil

        allow(Rails.logger).to receive(:warn)
        job.perform_now(key: key)

        expect(Rails.logger).to have_received(:warn).with(/expired before the job ran/)
        expect(DebouncedJobSpecJob.batches.sole[:batch_start]).to eq(32.minutes.ago)
      end
    end
  end

  describe "releasing the claim" do
    it "releases only after perform_batch completes, so a mid-flight event cannot open a second batch" do
      freeze_time do
        job.debounce(key: key, event_at: Time.current)

        observed = nil
        allow_any_instance_of(DebouncedJobSpecJob).to receive(:perform_batch) do
          observed = job.debounce_pending?(key)
        end

        job.perform_now(key: key)

        expect(observed).to be(true)
        expect(job.debounce_pending?(key)).to be(false)
      end
    end

    it "leaves the claim held when the batch raises" do
      allow_any_instance_of(DebouncedJobSpecJob).to receive(:perform_batch).and_raise("delivery is down")

      job.debounce(key: key, event_at: 1.minute.ago)
      expect { job.perform_now(key: key) }.to raise_error("delivery is down")

      expect(job.debounce_pending?(key)).to be(true)
      expect(job.batch_start_for(key)).to be_present
    end

    it "lets the next event start a fresh batch once the previous one finished" do
      freeze_time do
        first_at = Time.current
        job.debounce(key: key, event_at: first_at)
        travel 2.minutes
        job.perform_now(key: key)

        travel 1.minute
        later_at = Time.current
        expect(job.debounce(key: key, event_at: later_at)).to be(true)
        expect(job.batch_start_for(key)).to eq(later_at)
      end
    end
  end

  # Failure mode 4: an event lands after perform_batch has already queried
  # but before the claim is released. The claim being held makes a plain
  # `debounce` call at that moment a no-op, and the query that already ran
  # can't retroactively include it — without a rearm, it's gone for good.
  describe "events arriving mid-run" do
    it "rearms a follow-up run for an event that arrives while perform_batch is executing" do
      freeze_time do
        job.debounce(key: key, event_at: 30.seconds.ago)
        travel 2.minutes

        late_arrival = Time.current
        allow_any_instance_of(DebouncedJobSpecJob).to receive(:perform_batch) do
          # Simulates a comment landing after this job's own query already ran.
          expect(job.debounce(key: key, event_at: late_arrival)).to be(false)
        end

        expect {
          job.perform_now(key: key)
        }.to have_enqueued_job(DebouncedJobSpecJob).with(key: key)

        expect(job.debounce_pending?(key)).to be(true)
        expect(job.batch_start_for(key)).to eq(late_arrival)
      end
    end

    it "does not rearm when nothing arrives while perform_batch is executing" do
      freeze_time do
        job.debounce(key: key, event_at: Time.current)
        travel 2.minutes

        job.perform_now(key: key)

        expect(job.debounce_pending?(key)).to be(false)
        # Only the original debounce's own enqueue — no follow-up rearm.
        expect(enqueued_jobs.count { |j| j["job_class"] == "DebouncedJobSpecJob" }).to eq(1)
      end
    end

    it "keeps the earliest of several mid-run arrivals as the follow-up boundary" do
      freeze_time do
        job.debounce(key: key, event_at: Time.current)
        travel 2.minutes

        earlier = Time.current
        later = Time.current + 1.second
        allow_any_instance_of(DebouncedJobSpecJob).to receive(:perform_batch) do
          job.debounce(key: key, event_at: later)
          job.debounce(key: key, event_at: earlier)
        end

        job.perform_now(key: key)

        expect(job.batch_start_for(key)).to eq(earlier)
      end
    end

    it "does not treat an event still waiting out the window as mid-run" do
      freeze_time do
        job.debounce(key: key, event_at: Time.current)

        travel 10.seconds
        job.debounce(key: key, event_at: Time.current) # still waiting, perform hasn't started

        travel 2.minutes
        job.perform_now(key: key)

        expect(job.debounce_pending?(key)).to be(false) # released normally, no rearm needed
      end
    end
  end

  # Failure mode 5: `debounce` writes the claim, then perform_later fails
  # (adapter error, or a halted enqueue callback) before actually scheduling
  # anything. Without cleanup, every event for this key silently no-ops
  # until debounce_state_ttl expires, even though no job exists to run them.
  describe "when enqueueing fails" do
    it "releases the claim and re-raises when the queue adapter raises" do
      configured_job = double("configured_job")
      allow(job).to receive(:set).and_return(configured_job)
      allow(configured_job).to receive(:perform_later).and_raise(StandardError, "queue unavailable")

      expect {
        job.debounce(key: key, event_at: 1.minute.ago)
      }.to raise_error(StandardError, "queue unavailable")

      expect(job.debounce_pending?(key)).to be(false)
      expect(job.batch_start_for(key)).to be_nil
    end

    it "releases the claim when perform_later returns a job that wasn't actually enqueued" do
      configured_job = double("configured_job")
      allow(job).to receive(:set).and_return(configured_job)
      allow(configured_job).to receive(:perform_later).and_return(instance_double(DebouncedJobSpecJob, successfully_enqueued?: false))

      expect(job.debounce(key: key, event_at: 1.minute.ago)).to be(false)

      expect(job.debounce_pending?(key)).to be(false)
      expect(job.batch_start_for(key)).to be_nil
    end
  end

  describe "configuration" do
    it "defaults to the concern's window and retry horizon" do
      default_job = Class.new(CoPlan::ApplicationJob) { include CoPlan::DebouncedJob }

      expect(default_job.debounce_window).to eq(CoPlan::DebouncedJob::DEFAULT_WINDOW)
      expect(default_job.debounce_retry_horizon).to eq(CoPlan::DebouncedJob::DEFAULT_RETRY_HORIZON)
    end

    it "rejects a non-positive window or retry horizon" do
      klass = Class.new(CoPlan::ApplicationJob) { include CoPlan::DebouncedJob }

      expect { klass.debounces_with(window: -1.minute) }.to raise_error(ArgumentError, /positive duration/)
      expect { klass.debounces_with(retry_horizon: "soon") }.to raise_error(ArgumentError, /positive duration/)
    end
  end
end
