FactoryBot.define do
  factory :plan_tag, class: "CoPlan::PlanTag" do
    plan
    tag
  end
end
