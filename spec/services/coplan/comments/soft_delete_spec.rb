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

    it "writes a comment_deleted PlanEvent with body preview metadata" do
      expect {
        described_class.call(comment: comment, actor: user)
      }.to change { CoPlan::PlanEvent.where(event_type: "comment_deleted").count }.by(1)

      event = CoPlan::PlanEvent.where(event_type: "comment_deleted").last
      expect(event.plan).to eq(plan)
      expect(event.actor_user).to eq(user)
      expect(event.metadata).to include(
        "comment_id" => comment.id,
        "thread_id" => thread.id,
        "body_preview" => "Hello world"
      )
    end

    it "is idempotent — no extra PlanEvent on a second call" do
      described_class.call(comment: comment, actor: user)
      expect {
        described_class.call(comment: comment, actor: user)
      }.not_to change { CoPlan::PlanEvent.count }
    end

    it "truncates long bodies in the preview" do
      long = "x" * 500
      comment.update!(body_markdown: long)
      described_class.call(comment: comment, actor: user)
      preview = CoPlan::PlanEvent.where(event_type: "comment_deleted").last.metadata["body_preview"]
      expect(preview.length).to be <= described_class::BODY_PREVIEW_LENGTH
    end
  end
end
