require "rails_helper"

RSpec.describe CoPlan::SummarizePlanJob, type: :job do
  include ActiveJob::TestHelper

  let(:plan) { create(:plan) }
  let(:current_sha) { plan.current_plan_version.content_sha256 }

  before do
    allow(CoPlan::Ai).to receive(:call).and_return("Fresh summary.")
  end

  describe "#perform" do
    it "passes the summarize prompt and plan content to CoPlan::Ai" do
      described_class.perform_now(plan_id: plan.id)

      expect(CoPlan::Ai).to have_received(:call).with(
        system_prompt: File.read(CoPlan::SummarizePlanJob::PROMPT_PATH),
        user_content: plan.current_content
      )
    end

    it "updates summary, generated_at, and sha when content has changed" do
      freeze_time do
        expect {
          described_class.perform_now(plan_id: plan.id)
        }.to change { plan.reload.summary }.from(nil).to("Fresh summary.")
          .and change { plan.reload.summary_content_sha256 }.from(nil).to(current_sha)

        expect(plan.reload.summary_generated_at).to eq(Time.current)
      end
    end

    it "strips whitespace from the AI response before persisting" do
      allow(CoPlan::Ai).to receive(:call).and_return("  trimmed\n\n")

      described_class.perform_now(plan_id: plan.id)

      expect(plan.reload.summary).to eq("trimmed")
    end

    it "no-ops when summary_content_sha256 already matches current content" do
      plan.update!(
        summary: "Existing.",
        summary_generated_at: 1.hour.ago,
        summary_content_sha256: current_sha
      )

      described_class.perform_now(plan_id: plan.id)

      expect(CoPlan::Ai).not_to have_received(:call)
      expect(plan.reload.summary).to eq("Existing.")
    end

    it "regenerates when a new PlanVersion changes the content sha" do
      plan.update!(summary: "Old.", summary_content_sha256: current_sha, summary_generated_at: 1.hour.ago)
      new_version = create(:plan_version, plan: plan, revision: plan.current_revision + 1,
                                          content_markdown: "# New content\n\nDifferent text.")
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)

      described_class.perform_now(plan_id: plan.id)

      expect(plan.reload.summary).to eq("Fresh summary.")
      expect(plan.summary_content_sha256).to eq(new_version.content_sha256)
    end

    it "does not update when the AI returns blank" do
      allow(CoPlan::Ai).to receive(:call).and_return("   \n")

      expect {
        described_class.perform_now(plan_id: plan.id)
      }.not_to change { plan.reload.summary }
    end

    it "no-ops when the plan has no current version" do
      plan.update_columns(current_plan_version_id: nil, current_revision: 0)

      described_class.perform_now(plan_id: plan.id)

      expect(CoPlan::Ai).not_to have_received(:call)
    end

    it "no-ops when the plan has been deleted" do
      missing_id = SecureRandom.uuid

      expect {
        described_class.perform_now(plan_id: missing_id)
      }.not_to raise_error
      expect(CoPlan::Ai).not_to have_received(:call)
    end

    # Race-condition guard: a slow job started against revision N must
    # NOT overwrite a fresher summary already persisted for revision N+1.
    it "does not overwrite a fresher summary when a newer version landed mid-flight" do
      stale_sha = current_sha

      # Simulate "a newer version landed while the AI was thinking" by
      # mutating the plan's current_plan_version between the AI call and
      # the persist step.
      allow(CoPlan::Ai).to receive(:call) do
        newer = create(:plan_version, plan: plan, revision: plan.current_revision + 1,
                                       content_markdown: "# Fresher\n\nNewer body.")
        plan.update!(current_plan_version: newer, current_revision: newer.revision,
                     summary: "Fresher summary persisted by the newer job.",
                     summary_content_sha256: newer.content_sha256,
                     summary_generated_at: Time.current)
        "Stale summary from the slow job."
      end

      described_class.perform_now(plan_id: plan.id)

      expect(plan.reload.summary).to eq("Fresher summary persisted by the newer job.")
      expect(plan.summary_content_sha256).not_to eq(stale_sha)
    end

    it "discards on AI errors instead of retrying" do
      allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "boom")

      expect {
        perform_enqueued_jobs { described_class.perform_later(plan_id: plan.id) }
      }.not_to raise_error
    end

    it "enqueues on the default queue" do
      existing_plan_id = plan.id
      expect {
        described_class.perform_later(plan_id: existing_plan_id)
      }.to have_enqueued_job(described_class).on_queue("default").with(plan_id: existing_plan_id)
    end
  end

  describe "PlanVersion after_create_commit hook" do
    it "enqueues SummarizePlanJob when a new version is created" do
      existing_plan = create(:plan)

      expect {
        create(:plan_version, plan: existing_plan, revision: existing_plan.current_revision + 1)
      }.to have_enqueued_job(described_class).with(plan_id: existing_plan.id)
    end
  end
end
