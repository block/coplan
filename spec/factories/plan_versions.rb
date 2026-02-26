FactoryBot.define do
  factory :plan_version, class: "CoPlan::PlanVersion" do
    plan
    sequence(:revision) { |n| n }
    content_markdown { "# Plan Content\n\nSome content here." }
    actor_type { "human" }
    actor_id { nil }
  end
end
