require "rails_helper"

RSpec.describe SlackNotificationJob, type: :job do
  let(:plan_author) { create(:coplan_user, email: "author@example.com") }
  let(:commenter) { create(:coplan_user, email: "commenter@example.com") }
  let(:plan) { create(:plan, created_by_user: plan_author) }

  let(:thread_record) do
    create(:comment_thread, plan: plan,
      plan_version: plan.current_plan_version, created_by_user: commenter)
  end

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_cache
  end

  before do
    allow(SlackClient).to receive(:configured?).and_return(true)
    allow(SlackClient).to receive(:send_dm)
  end

  describe "#perform" do
    let!(:first_comment) do
      thread_record.comments.create!(
        author_type: "human",
        author_id: commenter.id, body_markdown: "A comment body."
      )
    end

    it "sends a DM to the plan author for the thread's first comment" do
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

    it "skips notification when the thread has no comments in the batch window" do
      first_comment.destroy!

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).not_to have_received(:send_dm)
    end

    it "skips notification when Slack is not configured" do
      allow(SlackClient).to receive(:configured?).and_return(false)

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).not_to have_received(:send_dm)
    end
  end

  describe "replies" do
    let(:other_participant) { create(:coplan_user, email: "other@example.com") }

    before do
      # An hour-old comment, clearly outside this batch — simulates it
      # having already been notified about in an earlier run.
      travel_to 1.hour.ago do
        thread_record.comments.create!(
          author_type: "human", author_id: commenter.id, body_markdown: "First comment."
        )
      end
      Rails.cache.write(described_class.batch_start_key(thread_record.id), 30.minutes.ago)
    end

    it "notifies the plan author and prior participants, excluding the replier" do
      thread_record.comments.create!(
        author_type: "human", author_id: other_participant.id, body_markdown: "Someone else chimes in."
      )

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).to have_received(:send_dm).with(email: plan_author.email, text: anything)
      expect(SlackClient).to have_received(:send_dm).with(email: commenter.email, text: anything)
      expect(SlackClient).not_to have_received(:send_dm).with(email: other_participant.email, text: anything)
    end

    it "does not notify the replier about their own reply" do
      thread_record.comments.create!(
        author_type: "human", author_id: commenter.id, body_markdown: "Following up on my own thread."
      )

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).not_to have_received(:send_dm).with(email: commenter.email, text: anything)
    end
  end

  describe ".debounce" do
    it "schedules exactly one delayed job for a burst of comments on the same thread" do
      expect {
        3.times { described_class.debounce(comment_thread_id: thread_record.id) }
      }.to have_enqueued_job(described_class).exactly(1).times.on_queue("default")
    end

    it "coalesces every comment created during the debounce window into one message per recipient" do
      Rails.cache.write(described_class.batch_start_key(thread_record.id), 30.minutes.ago)
      other_participant = create(:coplan_user)
      thread_record.comments.create!(author_type: "human", author_id: other_participant.id, body_markdown: "First.")
      thread_record.comments.create!(author_type: "human", author_id: other_participant.id, body_markdown: "Second.")
      thread_record.comments.create!(author_type: "human", author_id: other_participant.id, body_markdown: "Third.")

      described_class.perform_now(comment_thread_id: thread_record.id)

      expect(SlackClient).to have_received(:send_dm).with(
        email: plan_author.email,
        text: a_string_including("3 new comments").and(a_string_including("Third."))
      ).once
    end

    it "allows a new burst after the previous one has been sent" do
      thread_record.comments.create!(author_type: "human", author_id: commenter.id, body_markdown: "First.")

      described_class.debounce(comment_thread_id: thread_record.id)
      described_class.perform_now(comment_thread_id: thread_record.id)

      expect {
        described_class.debounce(comment_thread_id: thread_record.id)
      }.to have_enqueued_job(described_class).on_queue("default")
    end
  end

  describe "error handling" do
    let!(:first_comment) do
      thread_record.comments.create!(
        author_type: "human", author_id: commenter.id, body_markdown: "First comment."
      )
    end

    it "skips a recipient with a permanent Slack error but keeps notifying others" do
      other_participant = create(:coplan_user, email: "other@example.com")
      thread_record.comments.create!(
        author_type: "human", author_id: other_participant.id, body_markdown: "Reply."
      )
      allow(SlackClient).to receive(:send_dm).with(email: plan_author.email, text: anything)
        .and_raise(SlackClient::PermanentError, "users_not_found")

      expect {
        described_class.perform_now(comment_thread_id: thread_record.id)
      }.not_to raise_error

      expect(SlackClient).to have_received(:send_dm).with(email: commenter.email, text: anything)
    end

    it "retries the whole batch on a transient Slack error" do
      allow(SlackClient).to receive(:send_dm).and_raise(SlackClient::Error, "ratelimited")

      expect {
        described_class.perform_now(comment_thread_id: thread_record.id)
      }.to have_enqueued_job(described_class)
    end
  end
end
