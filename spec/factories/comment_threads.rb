FactoryBot.define do
  factory :comment_thread do
    plan
    organization { plan.organization }
    plan_version { plan.current_plan_version }
    created_by_user { association(:user, organization: plan.organization) }
    status { "open" }
    out_of_date { false }

    trait :with_anchor do
      anchor_text { "some anchor text" }
    end

    trait :resolved do
      status { "resolved" }
      association :resolved_by_user, factory: :user
    end
  end
end
