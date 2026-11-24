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
    config.vapid_public_key = "pub"
    config.vapid_private_key = "priv"
    config.vapid_subject = "mailto:test@example.com"
    example.run
  ensure
    Rails.cache = previous_cache
    config.vapid_public_key = config.vapid_private_key = config.vapid_subject = nil
  end

  before do
    # Windows are fixed slots; don't let a test straddle two.
    freeze_time
    stub_const("#{described_class}::LIMIT", 6)
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

    travel(described_class::WINDOW) { reply("Later") }
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
end
