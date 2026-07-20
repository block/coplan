FactoryBot.define do
  factory :plan, class: "CoPlan::Plan" do
    created_by_user { association(:coplan_user) }
    sequence(:title) { |n| "Plan #{n}" }
    visibility { "draft" }
    tags { [] }
    metadata { {} }

    after(:create) do |plan|
      unless plan.current_plan_version
        version = create(:plan_version, plan: plan, revision: 1, actor_id: plan.created_by_user_id)
        plan.update_columns(current_plan_version_id: version.id, current_revision: 1)
      end
    end

    trait :draft do
      visibility { "draft" }
    end

    trait :published do
      visibility { "published" }
    end

    trait :archived do
      visibility { "published" }
      archived_at { Time.current }
    end

    # Legacy status traits, mapped onto visibility/archived so the many
    # existing specs that build lifecycle-era plans keep working. New specs
    # should use :draft / :published / :archived directly.
    trait :brainstorm do
      visibility { "draft" }
    end

    trait :considering do
      visibility { "published" }
    end

    trait :developing do
      visibility { "published" }
    end

    trait :live do
      visibility { "published" }
    end

    trait :abandoned do
      visibility { "published" }
      archived_at { Time.current }
    end
  end
end
