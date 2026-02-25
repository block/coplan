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
  let!(:first_comment) do
    thread_record.comments.create!(
      organization: org, author_type: "human",
      author_id: commenter.id, body_markdown: "A comment body."
    )
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

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).to have_received(:send_dm).with(
        email: plan_author.email,
        text: a_string_including("some highlighted text").and(a_string_including("A comment body."))
      )
    end

    it "includes first comment body in the message" do
      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).to have_received(:send_dm).with(
        email: plan_author.email,
        text: a_string_including("A comment body.")
      )
    end

    it "skips notification when first comment author is the plan author" do
      first_comment.update_columns(author_id: plan_author.id)

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).not_to have_received(:send_dm)
    end

    it "sends notification for non-human comments (e.g. automated reviews)" do
      first_comment.update_columns(author_type: "cloud_persona")

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).to have_received(:send_dm)
    end

    it "skips notification when thread has no comments" do
      first_comment.destroy!

      described_class.perform_now(comment_thread_id: thread_record.id)

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
