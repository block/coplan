require "rails_helper"

RSpec.describe CoPlan::ReviewResponse do
  let(:request) { create(:review_request) }

  it "records an immutable response with the exact reviewer and version" do
    response = request.review_responses.create!(user: request.reviewer, plan_version: request.plan.current_plan_version,
      decision: "approved", actor_type: "human", note: "Satisfied with this version")
    expect { response.update!(note: "Changed later") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { response.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "rejects responses attributed to someone else or another plan" do
    response = request.review_responses.build(user: create(:coplan_user), plan_version: create(:plan).current_plan_version,
      decision: "approved", actor_type: "human")
    expect(response).not_to be_valid
    expect(response.errors[:user]).to be_present
    expect(response.errors[:plan_version]).to be_present
  end
end
