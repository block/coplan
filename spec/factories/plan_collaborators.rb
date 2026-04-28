FactoryBot.define do
  factory :plan_collaborator, class: "CoPlan::PlanCollaborator" do
    plan
    user { association(:coplan_user) }
    role { "reviewer" }

    trait :approver do
      role { "approver" }
    end

    trait :highlighted do
      role { "highlighted" }
      highlighted_reason { "Domain expert" }
    end
  end
end
