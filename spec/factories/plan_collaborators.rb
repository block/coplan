FactoryBot.define do
  factory :plan_collaborator, class: "CoPlan::PlanCollaborator" do
    plan
    user { association(:coplan_user) }
    role { "reviewer" }
  end
end
