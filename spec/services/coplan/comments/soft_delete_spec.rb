require "rails_helper"

RSpec.describe CoPlan::Comments::SoftDelete do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:thread) { create(:comment_thread, plan: plan, created_by_user: user) }
  let(:comment) { create(:comment, comment_thread: thread, author_type: "human", author_id: user.id, body_markdown: "Hello world") }

  describe ".call" do
    it "soft-deletes the comment" do
      expect {
        described_class.call(comment: comment, actor: user)
      }.to change { comment.reload.deleted_at }.from(nil)
    end

    it "writes a comment_deleted PlanEvent that keeps no copy of the text" do
      expect {
        described_class.call(comment: comment, actor: user)
      }.to change { CoPlan::PlanEvent.where(event_type: "comment_deleted").count }.by(1)

      event = CoPlan::PlanEvent.where(event_type: "comment_deleted").last
      expect(event.plan).to eq(plan)
      expect(event.actor_user).to eq(user)
      expect(event.metadata).to eq("comment_id" => comment.id, "thread_id" => thread.id)
    end

    it "is idempotent — no extra PlanEvent on a second call" do
      described_class.call(comment: comment, actor: user)
      expect {
        described_class.call(comment: comment, actor: user)
      }.not_to change { CoPlan::PlanEvent.count }
    end

    it "leaves no copy of the deleted text in the comment, its history or its queued agent events" do
      token = create(:api_token, user: user)
      CoPlan::AgentEvent.create!(api_token: token, plan: plan, comment_thread_id: thread.id, comment_id: comment.id,
        event_type: "comment.created", payload: { "comment_body" => "Hello world", "plan_title" => plan.title })

      described_class.call(comment: comment, actor: user)

      expect(comment.reload.body_markdown).to eq(CoPlan::Comment::DELETED_BODY)
      stored = [
        CoPlan::Comment.where(id: comment.id).pluck(:body_markdown),
        CoPlan::PlanEvent.where(plan: plan).pluck(:metadata),
        CoPlan::AgentEvent.where(comment_id: comment.id).pluck(:payload)
      ].to_json
      expect(stored).not_to include("Hello world")
      expect(CoPlan::AgentEvent.find_by(comment_id: comment.id).payload["plan_title"]).to eq(plan.title)
    end
  end
end
