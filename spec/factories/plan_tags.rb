FactoryBot.define do
  factory :plan_tag, class: "Coplan::PlanTag" do
    plan
    tag
  end
end
