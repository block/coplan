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

  describe "#author" do
    it "resolves a human comment to its user via direct lookup" do
      user = create(:coplan_user)
      comment = create(:comment, author_type: "human", author_id: user.id)
      expect(comment.author).to eq(user)
    end

    it "resolves a local_agent comment to its user via direct lookup (no join)" do
      user = create(:coplan_user)
      comment = create(:comment, author_type: "local_agent", agent_name: "Amp", author_id: user.id)
      expect(comment.author).to eq(user)
    end

    it "returns nil for author types that don't map to a user" do
      comment = create(:comment, author_type: "system", author_id: SecureRandom.uuid)
      expect(comment.author).to be_nil
    end
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
