require "rails_helper"

RSpec.describe Comment, type: :model do
  it "is valid with valid attributes" do
    comment = create(:comment)
    expect(comment).to be_valid
  end

  it "validates body_markdown presence" do
    comment = build(:comment, body_markdown: "")
    expect(comment).not_to be_valid
    expect(comment.errors[:body_markdown]).to include("can't be blank")
  end

  it "validates author_type inclusion" do
    comment = build(:comment, author_type: "unknown")
    expect(comment).not_to be_valid
    expect(comment.errors[:author_type]).to include("is not included in the list")
  end

  it "belongs to comment_thread" do
    thread = create(:comment_thread)
    comment = create(:comment, comment_thread: thread, organization: thread.organization)
    expect(comment.comment_thread).to eq(thread)
  end

  describe "Slack notification callback" do
    let(:thread_record) { create(:comment_thread) }

    it "enqueues SlackNotificationJob for the first comment in a thread" do
      expect {
        create(:comment, comment_thread: thread_record, organization: thread_record.organization)
      }.to have_enqueued_job(SlackNotificationJob).with(comment_thread_id: thread_record.id)
    end

    it "does not enqueue SlackNotificationJob for subsequent comments" do
      create(:comment, comment_thread: thread_record, organization: thread_record.organization)

      expect {
        create(:comment, comment_thread: thread_record, organization: thread_record.organization)
      }.not_to have_enqueued_job(SlackNotificationJob)
    end
  end
end
