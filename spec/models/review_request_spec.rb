require "rails_helper"

RSpec.describe CoPlan::ReviewRequest do
  it "enforces one current assignment while retaining multiple ended assignments" do
    original = create(:review_request)
    2.times do
      original.update!(status: "removed")
      expect(original.current_assignment).to be_nil
      original = create(:review_request, plan: original.plan, reviewer: original.reviewer)
    end
    expect(original.plan.review_requests.count).to eq(3)
    expect(original.plan.review_requests.current.count).to eq(1)
    duplicate = original.attributes.except("id", "created_at", "updated_at").merge("id" => SecureRandom.uuid)
    expect { described_class.insert_all!([ duplicate ]) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "keeps a review task pending after its notification is read" do
    request = create(:review_request)
    notification = create(:notification, user: request.reviewer, plan: request.plan,
      comment_thread: nil, review_request: request, reason: "review_requested")
    notification.mark_read!
    expect(request.reload).to be_pending
  end

  it "accepts only supported reset reasons or no reset reason" do
    request = create(:review_request)
    [ nil, *CoPlan::ReviewRequest::RESET_REASONS ].each do |reason|
      request.reset_reason = reason
      expect(request).to be_valid
    end
    request.reset_reason = "content_change"
    expect(request).not_to be_valid
    expect(request.errors[:reset_reason]).to be_present
  end

  it "rejects duplicate assignments, invalid requirements and unrelated versions" do
    request = create(:review_request)
    expect(build(:review_request, plan: request.plan, reviewer: request.reviewer)).not_to be_valid
    expect(build(:review_request, requirement: "team")).not_to be_valid
    expect(build(:review_request, plan: request.plan, requested_plan_version: create(:plan).current_plan_version)).not_to be_valid
  end
end
