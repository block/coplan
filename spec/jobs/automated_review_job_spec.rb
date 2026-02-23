require "rails_helper"

RSpec.describe AutomatedReviewJob, type: :job do
  let(:plan) { create(:plan, :considering) }
  let(:reviewer) { create(:automated_plan_reviewer, organization: plan.organization) }
  let(:user) { plan.created_by_user }

  before do
    allow(AiProviders::OpenAi).to receive(:call).and_return("## Security Review\n\nLooks good overall.")
  end

  describe "#perform" do
    it "creates a comment thread with the AI response" do
      expect {
        described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)
      }.to change(CommentThread, :count).by(1)
        .and change(Comment, :count).by(1)
    end

    it "creates the comment with cloud_persona author type" do
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)

      comment = Comment.last
      expect(comment.author_type).to eq("cloud_persona")
      expect(comment.author_id).to eq(reviewer.id)
      expect(comment.body_markdown).to eq("## Security Review\n\nLooks good overall.")
    end

    it "creates a general (non-anchored) comment thread" do
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)

      thread = CommentThread.last
      expect(thread.anchor_text).to be_nil
      expect(thread.plan_version).to eq(plan.current_plan_version)
      expect(thread.status).to eq("open")
    end

    it "sets the triggered_by user as the thread creator" do
      other_user = create(:user, organization: plan.organization)
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: other_user)

      expect(CommentThread.last.created_by_user).to eq(other_user)
    end

    it "falls back to plan author when triggered_by is nil" do
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id)

      expect(CommentThread.last.created_by_user).to eq(plan.created_by_user)
    end

    it "calls the AI provider with the reviewer prompt and plan content" do
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)

      expect(AiProviders::OpenAi).to have_received(:call).with(
        system_prompt: reviewer.prompt_text,
        user_content: plan.current_plan_version.content_markdown,
        model: reviewer.ai_model
      )
    end

    it "does nothing if the reviewer is disabled" do
      reviewer.update!(enabled: false)

      expect {
        described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)
      }.not_to change(CommentThread, :count)
    end

    it "does nothing if the plan has no current version" do
      plan.update_columns(current_plan_version_id: nil)

      expect {
        described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)
      }.not_to change(CommentThread, :count)
    end

    it "enqueues on the default queue" do
      expect {
        described_class.perform_later(plan_id: plan.id, reviewer_id: reviewer.id)
      }.to have_enqueued_job(described_class).on_queue("default")
    end
  end
end
