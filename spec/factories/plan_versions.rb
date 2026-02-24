FactoryBot.define do
  factory :plan_version do
    plan
    organization { plan.organization }
    sequence(:revision) { |n| n }
    content_markdown { "# Plan Content\n\nSome content here." }
    actor_type { "human" }
    actor_id { nil }
  end
end
