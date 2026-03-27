FactoryBot.define do
  factory :plan_viewer, class: "CoPlan::PlanViewer" do
    plan
    user { association(:coplan_user) }
    last_seen_at { Time.current }
  end
end
