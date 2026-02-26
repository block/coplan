require "rails_helper"

RSpec.describe "AutomatedReviews", type: :request do
  let(:org) { create(:organization) }
  let(:user) { create(:user, :admin, organization: org) }
  let(:plan) { create(:plan, :considering, created_by_user: user) }
  let!(:reviewer) { create(:automated_plan_reviewer, enabled: true) }

  before { sign_in_as(user) }

  describe "POST #create" do
    it "enqueues an AutomatedReviewJob" do
      expect {
        post plan_automated_reviews_path(plan), params: { reviewer_id: reviewer.id }
      }.to have_enqueued_job(CoPlan::AutomatedReviewJob).with(
        plan_id: plan.id,
        reviewer_id: reviewer.id,
        plan_version_id: plan.current_plan_version_id,
        triggered_by: user
      )
    end

    it "redirects to the plan with a notice" do
      post plan_automated_reviews_path(plan), params: { reviewer_id: reviewer.id }
      expect(response).to redirect_to(plan_path(plan))
      expect(flash[:notice]).to include(reviewer.name)
    end

    it "returns 404 for disabled reviewers" do
      reviewer.update!(enabled: false)
      post plan_automated_reviews_path(plan), params: { reviewer_id: reviewer.id }
      expect(response).to have_http_status(:not_found)
    end
  end
end
