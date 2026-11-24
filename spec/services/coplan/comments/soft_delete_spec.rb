require "rails_helper"

RSpec.describe Coplan::Comments::SoftDelete do
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
      }.to change { Coplan::PlanEvent.where(event_type: "comment_deleted").count }.by(1)

      event = Coplan::PlanEvent.where(event_type: "comment_deleted").last
      expect(event.plan).to eq(plan)
      expect(event.actor_user).to eq(user)
      expect(event.metadata).to eq("comment_id" => comment.id, "thread_id" => thread.id)
    end

    it "is idempotent — no extra PlanEvent on a second call" do
      described_class.call(comment: comment, actor: user)
      expect {
        described_class.call(comment: comment, actor: user)
      }.not_to change { Coplan::PlanEvent.count }
    end

    it "retains the original body and queued payload while marking the comment deleted" do
      token = create(:api_token, user: user)
      event = Coplan::AgentEvent.create!(api_token: token, plan: plan, comment_thread_id: thread.id, comment_id: comment.id,
        event_type: "comment.created", payload: { "comment_body" => "Hello world", "plan_title" => plan.title })

      described_class.call(comment: comment, actor: user)

      expect(comment.reload).to have_attributes(body_markdown: "Hello world", deleted_at: be_present)
      expect(event.reload.payload["comment_body"]).to eq("Hello world")
      expect(event.as_api_json[:payload]["comment_body"]).to eq(Coplan::Comment::DELETED_BODY)
    end
  end
end
