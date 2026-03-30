require "rails_helper"

RSpec.describe CoPlan::Notifications::Create do
  let(:plan_author) { create(:coplan_user) }
  let(:reviewer) { create(:coplan_user) }
  let(:commenter) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: plan_author) }
  let(:thread) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: commenter) }

  before do
    allow(CoPlan::Broadcaster).to receive(:update_to)
  end

  describe "new_comment" do
    it "notifies the plan author" do
      expect {
        described_class.call(comment_thread: thread, actor_id: commenter.id, reason: "new_comment")
      }.to change(CoPlan::Notification, :count).by(1)

      notification = CoPlan::Notification.last
      expect(notification.user_id).to eq(plan_author.id)
      expect(notification.reason).to eq("new_comment")
    end

    it "does not notify the actor" do
      own_thread = create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: plan_author)
      result = described_class.call(comment_thread: own_thread, actor_id: plan_author.id, reason: "new_comment")
      expect(result).to be_nil
    end

    it "notifies plan collaborators with author/reviewer role" do
      create(:plan_collaborator, plan: plan, user: reviewer, role: "reviewer")

      expect {
        described_class.call(comment_thread: thread, actor_id: commenter.id, reason: "new_comment")
      }.to change(CoPlan::Notification, :count).by(2)

      notified_user_ids = CoPlan::Notification.pluck(:user_id)
      expect(notified_user_ids).to contain_exactly(plan_author.id, reviewer.id)
    end

    it "does not notify viewer collaborators" do
      viewer = create(:coplan_user)
      create(:plan_collaborator, plan: plan, user: viewer, role: "viewer")

      described_class.call(comment_thread: thread, actor_id: commenter.id, reason: "new_comment")
      notified_user_ids = CoPlan::Notification.pluck(:user_id)
      expect(notified_user_ids).not_to include(viewer.id)
    end
  end

  describe "reply" do
    it "notifies thread creator and plan author" do
      expect {
        described_class.call(comment_thread: thread, actor_id: create(:coplan_user).id, reason: "reply")
      }.to change(CoPlan::Notification, :count).by(2)

      notified_user_ids = CoPlan::Notification.pluck(:user_id)
      expect(notified_user_ids).to contain_exactly(plan_author.id, commenter.id)
    end

    it "notifies prior human commenters in the thread" do
      prior_commenter = create(:coplan_user)
      create(:comment, comment_thread: thread, author_type: "human", author_id: prior_commenter.id)

      new_replier = create(:coplan_user)
      described_class.call(comment_thread: thread, actor_id: new_replier.id, reason: "reply")

      notified_user_ids = CoPlan::Notification.pluck(:user_id)
      expect(notified_user_ids).to include(prior_commenter.id)
    end
  end

  describe "agent_response" do
    it "notifies thread creator and plan author" do
      agent_user = create(:coplan_user)
      expect {
        described_class.call(comment_thread: thread, actor_id: agent_user.id, reason: "agent_response")
      }.to change(CoPlan::Notification, :count).by(2)

      notified_user_ids = CoPlan::Notification.pluck(:user_id)
      expect(notified_user_ids).to contain_exactly(plan_author.id, commenter.id)
    end
  end

  describe "status_change" do
    it "notifies thread creator" do
      expect {
        described_class.call(comment_thread: thread, actor_id: plan_author.id, reason: "status_change")
      }.to change(CoPlan::Notification, :count).by(1)

      notification = CoPlan::Notification.last
      expect(notification.user_id).to eq(commenter.id)
    end

    it "does not notify if the actor is the thread creator" do
      result = described_class.call(comment_thread: thread, actor_id: commenter.id, reason: "status_change")
      expect(result).to be_nil
    end
  end

  describe "broadcasting" do
    it "broadcasts badge updates to each notified user" do
      expect(CoPlan::Broadcaster).to receive(:update_to).with(
        "coplan_notifications:#{plan_author.id}",
        target: "inbox-badge",
        html: anything
      )

      described_class.call(comment_thread: thread, actor_id: commenter.id, reason: "new_comment")
    end
  end
end
