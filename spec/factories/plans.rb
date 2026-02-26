FactoryBot.define do
  factory :plan, class: "CoPlan::Plan" do
    created_by_user { association(:coplan_user) }
    sequence(:title) { |n| "Plan #{n}" }
    status { "brainstorm" }
    tags { [] }
    metadata { {} }

    after(:create) do |plan|
      unless plan.current_plan_version
        version = create(:plan_version, plan: plan, revision: 1, actor_id: plan.created_by_user_id)
        plan.update_columns(current_plan_version_id: version.id, current_revision: 1)
      end
    end

    trait :considering do
      status { "considering" }
    end

    trait :brainstorm do
      status { "brainstorm" }
    end
  end
end
