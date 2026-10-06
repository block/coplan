FactoryBot.define do
  factory :review_request, class: "CoPlan::ReviewRequest" do
    plan
    reviewer { association(:coplan_user) }
    requested_by_user { plan.created_by_user }
    requested_plan_version { plan.current_plan_version }
    requirement { "required" }
    status { "pending" }
    requested_at { Time.current }
  end

  factory :review_response, class: "CoPlan::ReviewResponse" do
    review_request
    plan_version { review_request.plan.current_plan_version }
    user { review_request.reviewer }
    decision { "approved" }
    actor_type { "human" }
  end
end
