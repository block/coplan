FactoryBot.define do
  factory :api_token do
    organization
    user { association(:user, organization: organization) }
    sequence(:name) { |n| "Token #{n}" }
    token_digest { Digest::SHA256.hexdigest(SecureRandom.hex(32)) }

    transient do
      raw_token { nil }
    end

    after(:build) do |token, evaluator|
      if evaluator.raw_token
        token.token_digest = Digest::SHA256.hexdigest(evaluator.raw_token)
      end
    end

    trait :revoked do
      revoked_at { 1.day.ago }
    end
  end
end
