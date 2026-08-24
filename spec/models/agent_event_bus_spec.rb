require "rails_helper"

RSpec.describe CoPlan::AgentEventBus do
  subject(:bus) { described_class.new(capacity: 2) }

  describe "#with_slot" do
    it "grants slots up to capacity and refuses beyond it" do
      bus.with_slot do |first|
        bus.with_slot do |second|
          bus.with_slot do |third|
            expect([ first, second, third ]).to eq([ true, true, false ])
          end
        end
      end
    end

    it "releases the slot when the block finishes" do
      bus.with_slot { |granted| expect(granted).to be(true) }
      bus.with_slot { |granted| expect(granted).to be(true) }

      expect(bus.held).to eq(0)
    end

    it "releases the slot even when the block raises" do
      expect { bus.with_slot { raise "boom" } }.to raise_error("boom")

      expect(bus.held).to eq(0)
    end
  end

  describe "#wait / #signal" do
    it "returns as soon as the key is signalled rather than sleeping it out" do
      started = Time.current
      waiter = Thread.new { bus.wait("token-1", timeout: 5) }

      # Give the waiter a moment to actually block before signalling.
      sleep 0.05 until bus.instance_variable_get(:@waiter_counts)["token-1"] == 1
      bus.signal("token-1")
      waiter.join(5)

      expect(Time.current - started).to be < 2
    end

    it "does not block when the timeout has already elapsed" do
      expect { bus.wait("token-1", timeout: 0) }.not_to raise_error
    end

    it "wakes up on its own to catch out-of-process writes" do
      started = Time.current
      bus.wait("nobody-will-signal", timeout: 30)

      # Bounded by CROSS_PROCESS_INTERVAL, not by the caller's timeout.
      expect(Time.current - started).to be < described_class::CROSS_PROCESS_INTERVAL + 2
    end
  end

  describe ".default_capacity" do
    it "reserves threads for ordinary web traffic" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("COPLAN_MAX_AGENT_STREAMS").and_return(nil)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("RAILS_MAX_THREADS", 3).and_return("10")

      expect(described_class.default_capacity).to eq(10 - described_class::RESERVED_THREADS)
    end

    it "never drops below one slot" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("COPLAN_MAX_AGENT_STREAMS").and_return(nil)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("RAILS_MAX_THREADS", 3).and_return("1")

      expect(described_class.default_capacity).to eq(1)
    end
  end
end
