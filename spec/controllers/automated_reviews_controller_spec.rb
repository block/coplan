require "rails_helper"

RSpec.describe AutomatedReviewsController, type: :controller do
  let(:org) { create(:organization) }
  let(:user) { create(:user, organization: org) }
  let(:plan) { create(:plan, organization: org, created_by_user: user) }
  let!(:reviewer) { create(:automated_plan_reviewer, organization: org, enabled: true) }

  before do
    session[:user_id] = user.id
  end

  describe "POST #create" do
    it "enqueues an AutomatedReviewJob" do
      expect {
        post :create, params: { plan_id: plan.id, reviewer_id: reviewer.id }
      }.to have_enqueued_job(AutomatedReviewJob).with(
        plan_id: plan.id,
        reviewer_id: reviewer.id,
        plan_version_id: plan.current_plan_version_id,
        triggered_by: user
      )
    end

    it "redirects to the plan with a notice" do
      post :create, params: { plan_id: plan.id, reviewer_id: reviewer.id }
      expect(response).to redirect_to(plan_path(plan))
      expect(flash[:notice]).to include(reviewer.name)
    end

    it "returns 404 for disabled reviewers" do
      reviewer.update!(enabled: false)
      expect {
        post :create, params: { plan_id: plan.id, reviewer_id: reviewer.id }
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
