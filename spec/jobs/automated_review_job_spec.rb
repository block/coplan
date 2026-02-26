require "rails_helper"

RSpec.describe CoPlan::AutomatedReviewJob, type: :job do
  let(:plan) { create(:plan, :considering) }
  let(:user) { plan.created_by_user }
  let(:reviewer) { create(:automated_plan_reviewer) }
  let(:version) { plan.current_plan_version }
  let(:plan_content) { version.content_markdown }

  let(:structured_response) do
    '[
      {"anchor_text": "Plan Content", "comment": "The title should be more specific."},
      {"anchor_text": "Some content here", "comment": "Expand on this section."},
      {"anchor_text": null, "comment": "Overall looks good."}
    ]'
  end

  let(:perform_args) { { plan_id: plan.id, reviewer_id: reviewer.id, plan_version_id: version.id, triggered_by: user } }

  before do
    allow(CoPlan::AiProviders::OpenAi).to receive(:call).and_return(structured_response)
  end

  describe "#perform" do
    it "creates one comment thread per feedback item" do
      expect {
        described_class.perform_now(**perform_args)
      }.to change(CoPlan::CommentThread, :count).by(3)
        .and change(CoPlan::Comment, :count).by(3)
    end

    it "anchors threads to matching plan text" do
      described_class.perform_now(**perform_args)

      threads = CoPlan::CommentThread.order(:created_at).last(3)
      expect(threads[0].anchor_text).to eq("Plan Content")
      expect(threads[1].anchor_text).to eq("Some content here")
      expect(threads[2].anchor_text).to be_nil
    end

    it "attaches threads to the pinned version, not the current one" do
      old_version = version
      new_version = create(:plan_version, plan: plan, revision: 2)
      plan.update!(current_plan_version: new_version, current_revision: 2)

      described_class.perform_now(plan_id: plan.id, reviewer_id: reviewer.id, plan_version_id: old_version.id, triggered_by: user)

      CoPlan::CommentThread.last(3).each do |thread|
        expect(thread.plan_version).to eq(old_version)
      end
    end

    it "creates comments with cloud_persona author type" do
      described_class.perform_now(**perform_args)

      CoPlan::Comment.last(3).each do |comment|
        expect(comment.author_type).to eq("cloud_persona")
        expect(comment.author_id).to eq(reviewer.id)
      end
    end

    it "sets the triggered_by user as the thread creator" do
      other_user = create(:user)
      described_class.perform_now(**perform_args.merge(triggered_by: other_user))

      CoPlan::CommentThread.last(3).each do |thread|
        expect(thread.created_by_user).to eq(other_user)
      end
    end

    it "falls back to plan author when triggered_by is nil" do
      described_class.perform_now(**perform_args.except(:triggered_by))

      CoPlan::CommentThread.last(3).each do |thread|
        expect(thread.created_by_user).to eq(plan.created_by_user)
      end
    end

    it "passes the formatted prompt to the AI provider" do
      described_class.perform_now(**perform_args)

      expect(CoPlan::AiProviders::OpenAi).to have_received(:call).with(
        system_prompt: CoPlan::Plans::ReviewPromptFormatter.call(reviewer_prompt: reviewer.prompt_text),
        user_content: plan_content,
        model: reviewer.ai_model
      )
    end

    it "falls back to a single unanchored comment for non-JSON AI responses" do
      allow(CoPlan::AiProviders::OpenAi).to receive(:call).and_return("Plain text review with no JSON.")

      expect {
        described_class.perform_now(**perform_args)
      }.to change(CoPlan::CommentThread, :count).by(1)

      thread = CoPlan::CommentThread.last
      expect(thread.anchor_text).to be_nil
      expect(thread.comments.first.body_markdown).to eq("Plain text review with no JSON.")
    end

    it "does nothing if the reviewer is disabled" do
      reviewer.update!(enabled: false)

      expect {
        described_class.perform_now(**perform_args)
      }.not_to change(CoPlan::CommentThread, :count)
    end

    it "enqueues on the default queue" do
      expect {
        described_class.perform_later(**perform_args)
      }.to have_enqueued_job(described_class).on_queue("default")
    end
  end
end
