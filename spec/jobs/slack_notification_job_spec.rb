require "rails_helper"

RSpec.describe SlackNotificationJob, type: :job do
  let(:org) { create(:organization) }
  let(:plan_author) { create(:user, organization: org) }
  let(:commenter) { create(:user, organization: org) }
  let(:plan) { create(:plan, organization: org, created_by_user: plan_author) }
  let(:thread_record) do
    create(:comment_thread, plan: plan, organization: org,
      plan_version: plan.current_plan_version, created_by_user: commenter)
  end

  before do
    allow(SlackClient).to receive(:configured?).and_return(true)
    allow(SlackClient).to receive(:send_dm)
  end

  describe "#perform" do
    it "sends a DM to the plan author" do
      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).to have_received(:send_dm).with(
        email: plan_author.email,
        text: a_string_including("New comment on *#{plan.title}*")
      )
    end

    it "includes both anchor text and comment body when present" do
      thread_record.update_columns(anchor_text: "some highlighted text")
      thread_record.comments.create!(
        organization: org, author_type: "human",
        author_id: commenter.id, body_markdown: "This needs work"
      )

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).to have_received(:send_dm).with(
        email: plan_author.email,
        text: a_string_including("some highlighted text").and(a_string_including("This needs work"))
      )
    end

    it "falls back to first comment body when no anchor text" do
      thread_record.comments.create!(
        organization: org,
        author_type: "human",
        author_id: commenter.id,
        body_markdown: "This needs work"
      )

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).to have_received(:send_dm).with(
        email: plan_author.email,
        text: a_string_including("This needs work")
      )
    end

    it "skips notification when commenter is the plan author" do
      self_thread = create(:comment_thread, plan: plan, organization: org,
        plan_version: plan.current_plan_version, created_by_user: plan_author)

      described_class.perform_now(comment_thread_id: self_thread.id)

      expect(SlackClient).not_to have_received(:send_dm)
    end

    it "skips notification when Slack is not configured" do
      allow(SlackClient).to receive(:configured?).and_return(false)

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).not_to have_received(:send_dm)
    end

    it "enqueues on the default queue" do
      thread_record # eagerly create to avoid callback enqueue inside expect block
      expect {
        described_class.perform_later(comment_thread_id: thread_record.id)
      }.to have_enqueued_job(described_class).on_queue("default")
    end

    it "discards permanent Slack errors without retrying" do
      allow(SlackClient).to receive(:send_dm).and_raise(SlackClient::PermanentError, "users_not_found")

      expect {
        described_class.perform_now(comment_thread_id: thread_record.id)
      }.not_to raise_error

      expect(SlackClient).to have_received(:send_dm).once
    end

    it "retries on transient Slack errors" do
      thread_record # eagerly create
      allow(SlackClient).to receive(:send_dm).and_raise(SlackClient::Error, "ratelimited")

      expect {
        described_class.perform_now(comment_thread_id: thread_record.id)
      }.to have_enqueued_job(described_class)
    end
  end
end
