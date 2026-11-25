require "rails_helper"
require "tmpdir"
require "timeout"

RSpec.describe Coplan::Notifications::FanoutBudget, "concurrent accounting" do
  self.use_transactional_tests = false

  let!(:actor) { create(:coplan_user) }

  around do |example|
    previous_cache = Rails.cache
    previous_limit = Coplan.configuration.notification_fanout_limit
    Coplan.configuration.notification_fanout_limit = 6
    Dir.mktmpdir("coplan-fanout") do |directory|
      Rails.cache = ActiveSupport::Cache::FileStore.new(directory)
      freeze_time { example.run }
    end
  ensure
    Rails.cache = previous_cache
    Coplan.configuration.notification_fanout_limit = previous_limit
  end

  after { actor.destroy! }

  it "serializes the first spend before reading a missing cache entry" do
    entered = Queue.new
    release = Queue.new
    waiting = Queue.new
    cache = Rails.cache
    first_id = nil
    allow(cache).to receive(:read).and_wrap_original do |method, *args|
      if Thread.current.object_id == first_id
        entered << true
        Timeout.timeout(10) { release.pop }
      end
      method.call(*args)
    end

    first = Thread.new do
      first_id = Thread.current.object_id
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.spend?(actor_id: actor.id, cost: 4)
      end
    end
    Timeout.timeout(10) { entered.pop }
    # The second worker reaches its real SQL lock while the first still has
    # not written the new key. A read/write without the row lock would let
    # both workers spend four against a six-delivery budget.
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        # Signal just before executing the lock query, not after it completes.
        allow(connection).to receive(:log).and_wrap_original do |method, sql, *args, **kwargs, &block|
          waiting << true if sql.match?(/coplan_users.*FOR UPDATE/i)
          method.call(sql, *args, **kwargs, &block)
        end
        described_class.spend?(actor_id: actor.id, cost: 4)
      end
    end
    Timeout.timeout(10) { waiting.pop }
    release << true

    expect(first.join(20)).to eq(first)
    expect(second.join(20)).to eq(second)
    expect([ first.value, second.value ]).to eq([ true, false ])
    expect(described_class.spend?(actor_id: actor.id, cost: 2)).to be(true)
    expect(described_class.spend?(actor_id: actor.id, cost: 1)).to be(false)
  ensure
    release << true if release
    [ first, second ].compact.each do |worker|
      worker.kill unless worker.join(5)
      worker.join
    end
  end

  it "ignores an outer request's stale local value" do
    # Use Rails' real local-cache strategy over a shared backing store.
    Rails.cache.singleton_class.prepend(ActiveSupport::Cache::Strategy::LocalCache)
    window = Coplan.configuration.notification_fanout_window
    slot = Time.current.to_i / window
    key = "coplan/notification_fanout/v2/#{actor.id}/#{window}/#{slot}"
    Rails.cache.with_local_cache do
      Rails.cache.write(key, 0)
      Rails.cache.with_local_cache { Rails.cache.write(key, 6) }
      expect(Rails.cache.read(key)).to eq(0)
      expect(described_class.spend?(actor_id: actor.id, cost: 1)).to be(false)
    end
  end
end
