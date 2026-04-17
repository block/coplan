FactoryBot.define do
  factory :reference, class: "CoPlan::Reference" do
    plan
    sequence(:url) { |n| "https://example.com/page-#{n}" }
    title { "Example Reference" }
    reference_type { "link" }
    source { "extracted" }

    trait :extracted do
      source { "extracted" }
    end
  end
end
