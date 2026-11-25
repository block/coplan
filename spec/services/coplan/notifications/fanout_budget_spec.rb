require "rails_helper"

RSpec.describe Coplan::Notifications::FanoutBudget do
  include ActiveJob::TestHelper

  let(:author) { create(:coplan_user) }
  let(:poster) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:thread) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: author) }

  around do |example|
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    config = Coplan.configuration
    previous_keys = [ config.vapid_public_key, config.vapid_private_key, config.vapid_subject ]
    previous_budget = [ config.notification_fanout_limit, config.notification_fanout_window ]
    previous_handlers = config.notification_delivery_handlers.dup
    config.notification_fanout_limit = 6
    config.vapid_public_key = "pub"
    config.vapid_private_key = "priv"
    config.vapid_subject = "mailto:test@example.com"
    example.run
  ensure
    Rails.cache = previous_cache
    config.vapid_public_key, config.vapid_private_key, config.vapid_subject = previous_keys
    config.notification_fanout_limit, config.notification_fanout_window = previous_budget
    config.notification_delivery_handlers.replace(previous_handlers)
  end

  before do
    # Windows are fixed slots; don't let a test straddle two.
    freeze_time
    create_list(:coplan_web_push_subscription, 3, user: author)
  end

  def reply(body, by: poster)
    comment = create(:comment, comment_thread: thread, author_type: "human", author_id: by.id, body_markdown: body)
    Coplan::Notifications::Create.call(comment_thread: thread, actor_id: by.id, comment: comment, reason: "reply")
  end

  def pushes
    enqueued_jobs.count { |job| job["job_class"] == "Coplan::WebPushDeliveryJob" }
  end

  it "stops pushing one person's notifications past the budget but keeps every inbox row" do
    3.times { |i| reply("Reply #{i}") }

    expect(Coplan::Notification.where(user: author).count).to eq(3)
    expect(pushes).to eq(6)
  end

  it "charges each person separately and starts again in the next window" do
    3.times { |i| reply("Reply #{i}") }
    reply("Someone else", by: create(:coplan_user))
    expect(pushes).to eq(9)

    travel(Coplan.configuration.notification_fanout_window) { reply("Later") }
    expect(pushes).to eq(12)
  end

  it "charges an agent's comments to the person behind it, whichever token posts" do
    3.times do |i|
      token = create(:api_token, user: poster)
      comment = create(:comment, comment_thread: thread, author_type: "local_agent", author_id: poster.id,
        api_token_id: token.id, agent_name: "Amp", body_markdown: "Agent reply #{i}")
      Coplan::Notifications::Create.call(comment_thread: thread, actor_id: token.id, comment: comment, reason: "agent_response")
    end

    expect(pushes).to eq(6)
  end

  it "applies to mentions too" do
    mentioned = create(:coplan_user, username: "bob")
    create_list(:coplan_web_push_subscription, 3, user: mentioned)
    3.times do |i|
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: poster.id,
        body_markdown: "[@bob](mention:bob) look #{i}")
      Coplan::Comments::ProcessMentions.call(comment)
    end

    expect(Coplan::Notification.where(user: mentioned, reason: "mention").count).to eq(3)
    expect(pushes).to eq(6)
  end


  it "counts the adapter dispatch alongside each push device" do
    Coplan.configuration.notification_fanout_limit = 8
    Coplan.configuration.notification_delivery_handlers << ->(_) { }
    3.times { |i| reply("Reply #{i}") }

    expect(Coplan::Notification.where(user: author).count).to eq(3)
    expect(pushes).to eq(6)
    expect(enqueued_jobs.count { |job| job["job_class"] == "Coplan::DispatchNotificationJob" }).to eq(2)
  end

  it "uses the host's window and does not catch up skipped deliveries" do
    Coplan.configuration.notification_fanout_window = 30.seconds
    3.times { |i| reply("Reply #{i}") }
    expect(pushes).to eq(6)

    travel(30.seconds) { reply("Later") }
    expect(pushes).to eq(9)
    expect(Coplan::Notification.where(user: author).count).to eq(4)
  end

  it "lets hosts disable the budget without accessing the cache" do
    Coplan.configuration.notification_fanout_limit = nil
    expect(Rails.cache).not_to receive(:read)
    3.times { |i| reply("Reply #{i}") }
    expect(pushes).to eq(9)
  end

  it "does not charge rejected work against the remaining budget" do
    expect(described_class.spend?(actor_id: poster.id, cost: 5)).to be(true)
    expect(described_class.spend?(actor_id: poster.id, cost: 2)).to be(false)
    expect(described_class.spend?(actor_id: poster.id, cost: 1)).to be(true)
    expect(described_class.spend?(actor_id: poster.id, cost: 1)).to be(false)
  end

  it "expires the old window without extending its lifetime on each spend" do
    window = Coplan.configuration.notification_fanout_window
    slot = Time.current.to_i / window
    key = "coplan/notification_fanout/v2/#{poster.id}/#{window}/#{slot}"
    travel_to(Time.at(slot * window))
    described_class.spend?(actor_id: poster.id, cost: 1)
    travel 1.minute
    described_class.spend?(actor_id: poster.id, cost: 1)
    expect(Rails.cache.read(key)).to eq(2)
    travel_to(Time.at((slot + 2) * window))
    expect(Rails.cache.read(key)).to be_nil
  end

  it "bypasses a null store even when a request-local cache is active" do
    Rails.cache = ActiveSupport::Cache::NullStore.new
    expect(Coplan::User).not_to receive(:lock)
    Rails.cache.with_local_cache do
      expect(described_class.spend?(actor_id: poster.id, cost: 7)).to be(true)
    end
  end

  it "does not require cache increment support for mentions" do
    allow(Rails.cache).to receive(:increment).and_raise(NotImplementedError)
    mentioned = create(:coplan_user, username: "bob")
    create(:coplan_web_push_subscription, user: mentioned)
    comment = create(:comment, comment_thread: thread, author_type: "human", author_id: poster.id,
      body_markdown: "[@bob](mention:bob) look")
    expect(Coplan::Notification.where(comment: comment, user: mentioned).count).to eq(1)
    expect(pushes).to eq(1)
  end

  [ :read, :write ].each do |operation|
    it "keeps all mention inbox rows and deliveries when cache #{operation} raises" do
      mentioned = [ create(:coplan_user, username: "bob"), create(:coplan_user, username: "alice") ]
      mentioned.each { |user| create(:coplan_web_push_subscription, user: user) }
      thread # Finish fixture callbacks before simulating a cache outage.
      allow(Rails.cache).to receive(operation).and_raise(NotImplementedError)
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: poster.id,
        body_markdown: "[@bob](mention:bob) [@alice](mention:alice) look")
      expect(Coplan::Notification.where(comment: comment, reason: "mention").count).to eq(2)
      expect(pushes).to eq(2)
    end
  end

  it "allows delivery when the store reports a failed write" do
    allow(Rails.cache).to receive(:write).and_return(false)
    reply("Still notify")
    expect(Coplan::Notification.where(user: author).count).to eq(1)
    expect(pushes).to eq(3)
  end

  it "keeps all queued recipients and badges when accounting fails" do
    coauthor = create(:coplan_user)
    create(:plan_collaborator, plan: plan, user: coauthor, role: "author")
    create(:coplan_web_push_subscription, user: coauthor)
    comment = create(:comment, comment_thread: thread, author_type: "human", author_id: poster.id, body_markdown: "Reply")
    allow(Rails.cache).to receive(:read).and_raise(IOError, "cache unavailable")
    expect(Coplan::Notifications::BroadcastBadges).to receive(:call).with(user_ids: contain_exactly(author.id, coauthor.id))

    Coplan::CreateNotificationsJob.perform_now(comment_thread_id: thread.id, actor_id: poster.id,
      comment_id: comment.id, reason: "reply")
    expect(Coplan::Notification.where(comment: comment).count).to eq(2)
    expect(pushes).to eq(4)
  end
end
