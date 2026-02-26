FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:name) { |n| "User #{n}" }
    role { "member" }

    trait :admin do
      role { "admin" }
    end
  end
end
