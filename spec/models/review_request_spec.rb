require "rails_helper"

RSpec.describe CoPlan::ReviewRequest do
  it "keeps a review task pending after its notification is read" do
    request = create(:review_request)
    notification = create(:notification, user: request.reviewer, plan: request.plan,
      comment_thread: nil, review_request: request, reason: "review_requested")
    notification.mark_read!
    expect(request.reload).to be_pending
  end

  it "rejects duplicate assignments, invalid requirements and unrelated versions" do
    request = create(:review_request)
    expect(build(:review_request, plan: request.plan, reviewer: request.reviewer)).not_to be_valid
    expect(build(:review_request, requirement: "team")).not_to be_valid
    expect(build(:review_request, plan: request.plan, requested_plan_version: create(:plan).current_plan_version)).not_to be_valid
  end
end
