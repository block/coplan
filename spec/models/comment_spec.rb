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
  end

  describe "soft delete" do
    let(:comment) { create(:comment) }

    it "soft_delete! sets deleted_at" do
      expect { comment.soft_delete! }.to change { comment.reload.deleted_at }.from(nil)
      expect(comment.deleted?).to be(true)
    end

    it "kept scope excludes deleted comments" do
      kept = create(:comment)
      deleted = create(:comment)
      deleted.soft_delete!

      expect(CoPlan::Comment.kept).to include(kept)
      expect(CoPlan::Comment.kept).not_to include(deleted)
    end

    it "does not re-fire ProcessMentions when soft-deleting" do
      comment # create before block, so ProcessMentions runs once on creation
      expect(CoPlan::Comments::ProcessMentions).not_to receive(:call)
      comment.soft_delete!
    end
  end
end
