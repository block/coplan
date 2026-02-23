require "rails_helper"

RSpec.describe AutomatedReviewJob, type: :job do
  let(:plan) { create(:plan, :considering) }
  let(:reviewer) { create(:automated_plan_reviewer, organization: plan.organization) }
  let(:user) { plan.created_by_user }
  let(:plan_content) { plan.current_plan_version.content_markdown }

  let(:structured_response) do
    '[
      {"anchor_text": "Plan Content", "comment": "The title should be more specific."},
      {"anchor_text": "Some content here", "comment": "Expand on this section."},
      {"anchor_text": null, "comment": "Overall looks good."}
    ]'
  end

  before do
    allow(AiProviders::OpenAi).to receive(:call).and_return(structured_response)
  end

  describe "#perform" do
    it "creates one comment thread per feedback item" do
      expect {
        described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)
      }.to change(CommentThread, :count).by(3)
        .and change(Comment, :count).by(3)
    end

    it "anchors threads to matching plan text" do
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)

      threads = CommentThread.order(:created_at).last(3)
      expect(threads[0].anchor_text).to eq("Plan Content")
      expect(threads[1].anchor_text).to eq("Some content here")
      expect(threads[2].anchor_text).to be_nil
    end

    it "creates comments with cloud_persona author type" do
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)

      Comment.last(3).each do |comment|
        expect(comment.author_type).to eq("cloud_persona")
        expect(comment.author_id).to eq(reviewer.id)
      end
    end

    it "sets the triggered_by user as the thread creator" do
      other_user = create(:user, organization: plan.organization)
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: other_user)

      CommentThread.last(3).each do |thread|
        expect(thread.created_by_user).to eq(other_user)
      end
    end

    it "falls back to plan author when triggered_by is nil" do
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id)

      CommentThread.last(3).each do |thread|
        expect(thread.created_by_user).to eq(plan.created_by_user)
      end
    end

    it "passes the formatted prompt to the AI provider" do
      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)

      expect(AiProviders::OpenAi).to have_received(:call).with(
        system_prompt: Plans::ReviewPromptFormatter.call(reviewer_prompt: reviewer.prompt_text),
        user_content: plan_content,
        model: reviewer.ai_model
      )
    end

    it "falls back to a single unanchored comment for non-JSON AI responses" do
      allow(AiProviders::OpenAi).to receive(:call).and_return("Plain text review with no JSON.")

      expect {
        described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, triggered_by: user)
      }.to change(CommentThread, :count).by(1)

      thread = CommentThread.last
      expect(thread.anchor_text).to be_nil
      expect(thread.comments.first.body_markdown).to eq("Plain text review with no JSON.")
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
