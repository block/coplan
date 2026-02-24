FactoryBot.define do
  factory :automated_plan_reviewer do
    organization
    sequence(:key) { |n| "reviewer-#{n}" }
    sequence(:name) { |n| "Reviewer #{n}" }
    prompt_text { "You are a reviewer. Review the plan." }
    enabled { true }
    trigger_statuses { [] }
    ai_provider { "openai" }
    ai_model { "gpt-4o" }
  end
end
