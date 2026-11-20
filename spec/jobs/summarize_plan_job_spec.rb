require "rails_helper"

RSpec.describe CoPlan::SummarizePlanJob, type: :job do
  include ActiveJob::TestHelper

  let(:plan) do
    create(:plan).tap do |record|
      set_version_fixture(record.current_plan_version, created_at: 2.minutes.ago)
    end
  end
  let(:current_sha) { plan.current_plan_version.content_sha256 }

  before do
    allow(CoPlan::Ai).to receive(:call).and_return("Fresh summary.")
  end

  describe "#perform" do
    it "passes the summarize prompt and plan content to CoPlan::Ai" do
      described_class.perform_now(plan_id: plan.id)

      expect(CoPlan::Ai).to have_received(:call).with(
        system_prompt: File.read(CoPlan::SummarizePlanJob::PROMPT_PATH),
        user_content: plan.current_content,
        intensity: :low
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

      travel_to(new_version.created_at + 1.minute, with_usec: true) do
        described_class.perform_now(plan_id: plan.id)
      end

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

    # Concurrency guard: two workers waking up against the same plan-and-sha
    # must collapse to a single AI call. Without the atomic claim, both jobs
    # would pass a naive pre-check and both burn an AI request.
    it "claims the sha before calling AI so a concurrent worker skips" do
      call_count = 0
      allow(CoPlan::Ai).to receive(:call) do
        call_count += 1
        # Simulate a second worker firing while we're mid-AI-call. With the
        # claim already taken, this inner perform should no-op.
        described_class.perform_now(plan_id: plan.id)
        "Fresh summary."
      end

      described_class.perform_now(plan_id: plan.id)

      expect(call_count).to eq(1)
      expect(plan.reload.summary).to eq("Fresh summary.")
    end

    it "does not claim a revision superseded after the job reads it" do
      existing_plan = plan
      job = described_class.new
      allow(job).to receive(:claim_version).and_wrap_original do |claim, record, version|
        CoPlan::Plans::ReplaceContent.call(plan: existing_plan, new_content: "# Newer\n\nStill editing.",
          base_revision: existing_plan.current_revision, actor_type: "human", actor_id: existing_plan.created_by_user_id)
        claim.call(record, version)
      end

      job.perform(plan_id: existing_plan.id, version_id: existing_plan.current_plan_version_id)

      expect(CoPlan::Ai).not_to have_received(:call)
      expect(existing_plan.reload.summary_content_sha256).to be_nil
    end

    it "skips a superseded job even when the latest version is already quiet" do
      existing_plan = plan
      old_version_id = existing_plan.current_plan_version_id
      result = CoPlan::Plans::ReplaceContent.call(plan: existing_plan, new_content: "# Newer\n\nFinal content.",
        base_revision: existing_plan.current_revision, actor_type: "human", actor_id: existing_plan.created_by_user_id)

      travel_to(result.fetch(:version).created_at + 1.minute, with_usec: true) do
        described_class.perform_now(plan_id: existing_plan.id, version_id: old_version_id)
        expect(CoPlan::Ai).not_to have_received(:call)

        described_class.perform_now(plan_id: existing_plan.id, version_id: result.fetch(:version).id)
        described_class.perform_now(plan_id: existing_plan.id)
        expect(CoPlan::Ai).to have_received(:call).once
      end
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

    it "defers an early job with legacy arguments until the current revision is quiet" do
      freeze_time do
        fresh_plan = create(:plan)
        version = fresh_plan.current_plan_version
        clear_enqueued_jobs

        expect {
          described_class.perform_now(plan_id: fresh_plan.id)
        }.to have_enqueued_job(described_class)
          .with(plan_id: fresh_plan.id, version_id: version.id).at(1.minute.from_now)
        expect(CoPlan::Ai).not_to have_received(:call)
        expect(fresh_plan.reload.summary_content_sha256).to be_nil

        travel 1.minute
        perform_enqueued_jobs(only: described_class, at: Time.current)
        expect(CoPlan::Ai).to have_received(:call).once
      end
    end

    it "discards on AI errors instead of retrying" do
      allow(CoPlan::Ai).to receive(:call).and_raise(CoPlan::Ai::Error, "boom")

      expect {
        perform_enqueued_jobs { described_class.perform_later(plan_id: plan.id) }
      }.not_to raise_error
    end

    it "discards a provider connection failure, preserving the summary and its sha claim" do
      generated_at = 1.hour.ago.change(usec: 0)
      plan.update!(summary: "Existing summary.", summary_generated_at: generated_at)
      allow(CoPlan::Ai).to receive(:call).and_call_original
      mock_client = instance_double(OpenAI::Client)
      allow(CoPlan::AiProviders::OpenAi).to receive(:client).and_return(mock_client)
      allow(mock_client).to receive(:chat).and_raise(Faraday::ConnectionFailed, '503 "Service Unavailable"')

      expect {
        expect {
          described_class.perform_now(plan_id: plan.id)
        }.not_to raise_error
      }.not_to have_enqueued_job(described_class)

      expect(plan.reload.summary).to eq("Existing summary.")
      expect(plan.summary_generated_at).to eq(generated_at)
      expect(plan.summary_content_sha256).to eq(current_sha)
      expect {
        described_class.perform_now(plan_id: plan.id)
      }.not_to have_enqueued_job(described_class)
      expect(mock_client).to have_received(:chat).once
    end

    it "enqueues on the default queue" do
      existing_plan_id = plan.id
      expect {
        described_class.perform_later(plan_id: existing_plan_id)
      }.to have_enqueued_job(described_class).on_queue("default").with(plan_id: existing_plan_id)
    end
  end

  describe "PlanVersion after_create_commit hook" do
    it "uses the host's quiet period for new versions and legacy jobs" do
      allow(CoPlan.configuration).to receive(:summary_debounce_delay).and_return(120)

      freeze_time do
        fresh_plan = create(:plan)
        version = fresh_plan.current_plan_version
        ready_at = 2.minutes.from_now
        expect(described_class).to have_been_enqueued
          .with(plan_id: fresh_plan.id, version_id: version.id).at(ready_at)

        travel 1.minute
        expect {
          described_class.perform_now(plan_id: fresh_plan.id)
        }.to have_enqueued_job(described_class)
          .with(plan_id: fresh_plan.id, version_id: version.id).at(ready_at)

        travel 59.seconds
        perform_enqueued_jobs(only: described_class, at: Time.current)
        expect(CoPlan::Ai).not_to have_received(:call)

        travel 1.second
        perform_enqueued_jobs(only: described_class, at: Time.current)
        expect(CoPlan::Ai).to have_received(:call).once
      end
    end

    it "can skip the quiet period when the host configures zero" do
      allow(CoPlan.configuration).to receive(:summary_debounce_delay).and_return(0)
      fresh_plan = create(:plan)

      described_class.perform_now(plan_id: fresh_plan.id, version_id: fresh_plan.current_plan_version_id)

      expect(CoPlan::Ai).to have_received(:call).once
      expect(fresh_plan.reload.summary).to eq("Fresh summary.")
    end

    it "summarizes only the last revision after a full minute without edits" do
      freeze_time do
        existing_plan = plan
        clear_enqueued_jobs

        CoPlan::Plans::ReplaceContent.call(plan: existing_plan, new_content: "# Draft\n\nFirst edit.",
          base_revision: existing_plan.current_revision, actor_type: "human", actor_id: existing_plan.created_by_user_id)

        travel 45.seconds
        latest_content = "# Draft\n\nFinal edit."
        result = CoPlan::Plans::ReplaceContent.call(plan: existing_plan, new_content: latest_content,
          base_revision: existing_plan.current_revision, actor_type: "human", actor_id: existing_plan.created_by_user_id)
        expect(described_class).to have_been_enqueued
          .with(plan_id: existing_plan.id, version_id: result.fetch(:version).id).at(1.minute.from_now)

        travel 59.seconds
        perform_enqueued_jobs(only: described_class, at: Time.current)
        expect(CoPlan::Ai).not_to have_received(:call)
        expect(existing_plan.reload.summary_content_sha256).to be_nil

        travel 1.second
        perform_enqueued_jobs(only: described_class, at: Time.current)
        expect(CoPlan::Ai).to have_received(:call).with(
          system_prompt: File.read(described_class::PROMPT_PATH),
          user_content: latest_content,
          intensity: :low
        ).once
        expect(existing_plan.reload.summary_content_sha256).to eq(result.fetch(:version).content_sha256)
      end
    end
  end
end
