require "rails_helper"

RSpec.describe CoPlan::Plans::TriggerAutomatedReviews do
  let!(:plan) { create(:plan, :considering) }
  let(:user) { plan.created_by_user }

  before do
    # Clear default reviewers created by Organization after_create callback
    CoPlan::AutomatedPlanReviewer.destroy_all
  end

  describe ".call" do
    it "enqueues jobs for reviewers that trigger on the given status" do
      reviewer = create(:automated_plan_reviewer,
        trigger_statuses: ["considering"],
        enabled: true
      )

      expect {
        described_class.call(plan: plan, new_status: "considering", triggered_by: user)
      }.to have_enqueued_job(CoPlan::AutomatedReviewJob).with(
        plan_id: plan.id,
        reviewer_id: reviewer.id,
        plan_version_id: plan.current_plan_version_id,
        triggered_by: user
      )
    end

    it "does not enqueue jobs for reviewers that do not trigger on the status" do
      create(:automated_plan_reviewer,
        trigger_statuses: ["developing"],
        enabled: true
      )

      expect {
        described_class.call(plan: plan, new_status: "considering", triggered_by: user)
      }.not_to have_enqueued_job(CoPlan::AutomatedReviewJob)
    end

    it "does not enqueue jobs for disabled reviewers" do
      create(:automated_plan_reviewer,
        trigger_statuses: ["considering"],
        enabled: false
      )

      expect {
        described_class.call(plan: plan, new_status: "considering", triggered_by: user)
      }.not_to have_enqueued_job(CoPlan::AutomatedReviewJob)
    end

    it "enqueues multiple jobs when multiple reviewers match" do
      create(:automated_plan_reviewer,
        trigger_statuses: ["considering"],
        enabled: true,
        key: "reviewer-a"
      )
      create(:automated_plan_reviewer,
        trigger_statuses: ["considering"],
        enabled: true,
        key: "reviewer-b"
      )

      expect {
        described_class.call(plan: plan, new_status: "considering", triggered_by: user)
      }.to have_enqueued_job(CoPlan::AutomatedReviewJob).exactly(2).times
    end

    it "does nothing when no reviewers exist" do
      expect {
        described_class.call(plan: plan, new_status: "considering", triggered_by: user)
      }.not_to have_enqueued_job(CoPlan::AutomatedReviewJob)
    end
  end
end
