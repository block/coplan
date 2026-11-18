require "rails_helper"
require "timeout"

RSpec.describe CoPlan::WebPushSubscription, "concurrent subscriptions", type: :model do
  self.use_transactional_tests = false

  let!(:users) { create_list(:coplan_user, 2) }

  after do
    users.each(&:destroy!)
  end

  [ "same", "different" ].each do |endpoint_kind|
    it "keeps concurrent #{endpoint_kind}-endpoint registrations for one account within the cap" do
      create_list(:coplan_web_push_subscription, described_class::MAX_PER_USER,
        user: users.first, last_seen_at: 1.day.ago)
      start = Queue.new
      endpoint = "https://example.com/concurrent-#{SecureRandom.hex(8)}"
      workers = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Timeout.timeout(10) { start.pop }
            described_class.upsert_for(user: users.first,
              endpoint: endpoint_kind == "same" ? endpoint : "#{endpoint}-#{index}",
              p256dh_key: "key", auth_key: "auth")
          end
        rescue StandardError => error
          error
        end
      end
      2.times { start << true }
      records = Timeout.timeout(10) { workers.map(&:value) }

      expect(records).to all(be_a(described_class))
      expect(records.map { |record| record.reload.id }.uniq.size).to eq(endpoint_kind == "same" ? 1 : 2)
      expect(users.first.web_push_subscriptions.count).to eq(described_class::MAX_PER_USER)
    ensure
      workers&.each { |worker| worker.join(10) }
    end
  end

  it "recovers a cross-account insert collision and retains the newly registered device at the cap" do
    create_list(:coplan_web_push_subscription, described_class::MAX_PER_USER,
      user: users.last, last_seen_at: 1.day.ago)
    endpoint = "https://example.com/shared-#{SecureRandom.hex(8)}"
    ready = Queue.new
    gates = users.to_h { |user| [ user.id, Queue.new ] }
    # Both real validations finish before either insert. The first account
    # commits while the second still holds its original transaction snapshot.
    barrier = proc do |record|
      if record.endpoint == endpoint
        ready << record.user_id
        Timeout.timeout(10) { gates.fetch(record.user_id).pop }
      end
    end
    described_class.set_callback(:create, :before, barrier)
    workers = users.map do |user|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.upsert_for(user: user, endpoint: endpoint, p256dh_key: "key", auth_key: "auth")
        end
      rescue StandardError => error
        error
      end
    end

    Timeout.timeout(10) { 2.times { ready.pop } }
    gates.fetch(users.first.id) << true
    first = Timeout.timeout(10) { workers.first.value }
    gates.fetch(users.last.id) << true
    second = Timeout.timeout(10) { workers.last.value }

    expect(first).to be_a(described_class)
    expect(second).to be_a(described_class)
    expect(second.reload.user_id).to eq(users.last.id)
    expect(users.last.web_push_subscriptions.count).to eq(described_class::MAX_PER_USER)
    expect(users.first.web_push_subscriptions.count).to eq(0)
  ensure
    gates&.each_value { |gate| gate << true }
    workers&.each { |worker| worker.join(10) }
    described_class.skip_callback(:create, :before, barrier) if barrier
  end
end
