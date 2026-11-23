FactoryBot.define do
  factory :plan_type, class: "Coplan::PlanType" do
    sequence(:name) { |n| "Plan Type #{n}" }
    description { "A plan type for testing" }
    default_tags { [] }
    template_content { "# Template\n\nDefault content." }
    metadata { {} }
  end
end
