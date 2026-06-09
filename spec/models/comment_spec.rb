require "rails_helper"

RSpec.describe CoPlan::Comment, type: :model do
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
    comment = create(:comment, comment_thread: thread)
    expect(comment.comment_thread).to eq(thread)
  end

  describe "Slack notification callback" do
    let(:thread_record) { create(:comment_thread) }

    it "enqueues NotificationJob for the first comment in a thread" do
      expect {
        create(:comment, comment_thread: thread_record)
      }.to have_enqueued_job(CoPlan::NotificationJob)
    end

    it "does not enqueue NotificationJob for subsequent comments" do
      create(:comment, comment_thread: thread_record)

      expect {
        create(:comment, comment_thread: thread_record)
      }.not_to have_enqueued_job(CoPlan::NotificationJob)
    end

    # Regression for COPLAN-30: `first_comment_in_thread?` used to compare
    # UUIDs with `id < ?`, which is not insertion-ordered. A reply whose UUID
    # sorts before the opener's was wrongly treated as the thread opener,
    # firing a duplicate "new comment thread" notification for the plan author.
    it "does not enqueue NotificationJob for a reply whose UUID sorts before the opener" do
      high_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      low_id  = "00000000-0000-0000-0000-000000000001"

      create(:comment, comment_thread: thread_record, id: high_id)

      expect {
        create(:comment, comment_thread: thread_record, id: low_id)
      }.not_to have_enqueued_job(CoPlan::NotificationJob)
    end
  end
end
