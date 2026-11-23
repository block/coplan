FactoryBot.define do
  factory :coplan_user, class: "Coplan::User" do
    sequence(:external_id) { |n| SecureRandom.uuid_v7 }
    sequence(:name) { |n| "User #{n}" }
    admin { false }
    metadata { {} }

    trait :admin do
      admin { true }
    end
  end
end
