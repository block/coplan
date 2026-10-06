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
end
