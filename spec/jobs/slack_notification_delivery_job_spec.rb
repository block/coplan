require "rails_helper"

RSpec.describe CoPlan::Slack::NotificationDeliveryJob, type: :job do
  let(:recipient) { create(:coplan_user, email: "recipient@example.com") }
  let(:author) { create(:coplan_user, email: "author@example.com") }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:thread) { create(:comment_thread, plan: plan, created_by_user: author) }
  let(:client) { instance_double(CoPlan::Slack::WebClient) }
  let(:key) { "#{recipient.id}:#{thread.id}" }

  around do |example|
    previous_cache = Rails.cache
    previous_config = CoPlan::Slack.configuration.to_h
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    config = CoPlan::Slack.configuration
    config.bot_token = "token"
    config.base_url = "https://coplan.example.test"
    CoPlan::Slack.configure { |slack| slack.notifications_enabled = true }
    example.run
  ensure
    Rails.cache = previous_cache
    previous_config.each { |name, value| config.public_send("#{name}=", value) }
    CoPlan.configuration.notification_delivery_handlers.delete(CoPlan::Slack.notification_delivery_handler)
  end

  before do
    allow(CoPlan::Slack::WebClient).to receive(:new).and_return(client)
    allow(client).to receive(:users_lookup_by_email).and_return("user" => { "id" => "U123" })
    allow(client).to receive(:chat_post_message).and_return("ts" => "123.456")
  end

  def record_notification(body, reason: "reply", read_at: nil)
    comment = create(:comment, comment_thread: thread, author_id: author.id, body_markdown: body)
    create(:notification, user: recipient, plan: plan, comment_thread: thread,
      comment: comment, reason: reason, read_at: read_at)
  end

  def notify(body, reason: "reply", read_at: nil)
    notification = record_notification(body, reason: reason, read_at: read_at)
    create(:notification_delivery, notification: notification)
    notification
  end

  it "groups unread comments for one recipient and thread into one DM" do
    first = notify("First comment")
    notify("Second comment")

    described_class.new.perform_batch(key: key, batch_start: first.created_at)

    expect(client).to have_received(:users_lookup_by_email).with(email: recipient.email).once
    expect(client).to have_received(:chat_post_message).with(
      channel: "U123",
      text: a_string_including("2 new comments", "First comment", "Second comment", "https://coplan.example.test/"),
      mrkdwn: true
    ).once
    expect(CoPlan::NotificationDelivery.where(status: "delivered").count).to eq(2)
  end

  it "skips comments the recipient has already cleared" do
    notification = notify("Already seen", read_at: Time.current)

    described_class.new.perform_batch(key: key, batch_start: notification.created_at)

    expect(client).not_to have_received(:chat_post_message)
    expect(notification.notification_deliveries.first.reload.status).to eq("skipped")
  end

  it "retries on a worker that has not enabled Slack delivery" do
    notification = notify("Comment")
    CoPlan::Slack.configuration.notifications_enabled = false

    expect { described_class.new.perform_batch(key: key, batch_start: notification.created_at) }
      .to raise_error(described_class::AdapterUnavailable)
    expect(notification.notification_deliveries.first.reload.status).to eq("pending")
  end

  it "includes an older notification when dispatch runs out of order" do
    older = record_notification("Older comment")
    newer = record_notification("Newer comment")
    handler = CoPlan::Slack.notification_delivery_handler

    handler.call(newer)
    handler.call(older)
    described_class.new.perform_batch(key: key, batch_start: newer.created_at)

    expect(client).to have_received(:chat_post_message).with(
      channel: "U123", text: a_string_including("Older comment", "Newer comment"), mrkdwn: true
    ).once
    expect(CoPlan::NotificationDelivery.where(status: "delivered").count).to eq(2)
  end

  it "records a permanent Slack failure without retrying the same intent" do
    notification = notify("Comment")
    allow(client).to receive(:users_lookup_by_email)
      .and_raise(CoPlan::Slack::WebClient::PermanentError, "users_not_found")
    allow(Rails.error).to receive(:report)

    described_class.new.perform_batch(key: key, batch_start: notification.created_at)

    expect(notification.notification_deliveries.first.reload.status).to eq("failed")
    expect(client).not_to have_received(:chat_post_message)
  end

  it "records exhausted retryable failures and releases the debounce claim" do
    notification = notify("Attempted comment")
    job = described_class.new(key: key)
    allow(Rails.error).to receive(:report)
    allow(client).to receive(:users_lookup_by_email)
      .and_raise(CoPlan::Slack::WebClient::RetryableError, "timeout")
    Rails.cache.write(described_class.debounce_pending_cache_key(key), true)

    expect { job.perform_batch(key: key, batch_start: notification.created_at) }
      .to raise_error(CoPlan::Slack::WebClient::RetryableError)
    later = notify("Later comment")
    job.fail_pending!(CoPlan::Slack::WebClient::RetryableError.new("timeout"))

    expect(notification.notification_deliveries.first.reload).to have_attributes(status: "failed", error_code: "timeout")
    expect(later.notification_deliveries.first.reload.status).to eq("pending")
    expect(described_class.debounce_pending?(key)).to be(true)
  end

  it "schedules one debounced delivery for a burst of eligible notifications" do
    first = notify("First")
    second = notify("Second")
    handler = CoPlan::Slack.notification_delivery_handler

    expect { handler.call(first); handler.call(second) }
      .to have_enqueued_job(described_class).exactly(1).times
  end

  it "keeps Slack disabled until the host opts in" do
    CoPlan::Slack.configuration.notifications_enabled = false
    notification = notify("No Slack")

    expect { CoPlan::Slack.notification_delivery_handler.call(notification) }
      .not_to have_enqueued_job(described_class)
  end

  it "does not deliver status changes" do
    notification = notify("Not a DM", reason: "status_change")

    expect { CoPlan::Slack.notification_delivery_handler.call(notification) }
      .not_to have_enqueued_job(described_class)
  end
end
