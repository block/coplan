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
  end
end
