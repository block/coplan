FactoryBot.define do
  factory :user do
    organization
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:name) { |n| "User #{n}" }
    org_role { "member" }

    trait :admin do
      org_role { "admin" }
    end
  end
end
