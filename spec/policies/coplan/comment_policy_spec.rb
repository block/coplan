require "rails_helper"

RSpec.describe CoPlan::CommentPolicy do
  let(:author) { create(:coplan_user) }
  let(:other_user) { create(:coplan_user) }
  let(:plan_author) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: plan_author) }
  let(:thread) { create(:comment_thread, plan: plan, created_by_user: author) }

  describe "#delete?" do
    it "allows the human author to delete their own comment" do
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: author.id)
      expect(described_class.new(author, comment).delete?).to be(true)
    end

    it "forbids another user from deleting someone else's comment" do
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: author.id)
      expect(described_class.new(other_user, comment).delete?).to be(false)
    end

    it "forbids the plan author from deleting comments they did not write" do
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: author.id)
      expect(described_class.new(plan_author, comment).delete?).to be(false)
    end

    it "forbids deleting agent comments even when caller matches author_id" do
      token = create(:api_token, user: author)
      comment = create(:comment, comment_thread: thread, author_type: "local_agent", author_id: token.id, agent_name: "Amp")
      expect(described_class.new(author, comment).delete?).to be(false)
    end

    it "forbids deleting when no user is present" do
      comment = create(:comment, comment_thread: thread, author_type: "human", author_id: author.id)
      expect(described_class.new(nil, comment).delete?).to be(false)
    end
  end
end
