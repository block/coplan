FactoryBot.define do
  factory :folder, class: "Coplan::Folder" do
    sequence(:name) { |n| "Folder #{n}" }
    created_by_user { association(:coplan_user) }
    # Folders live in a library; default to the parent's (so nested
    # factories share one library) or the creator's own (the common case
    # in specs: `create(:folder, created_by_user: author)`).
    library { parent&.library || created_by_user.library }
  end

  factory :plan_placement, class: "Coplan::PlanPlacement" do
    plan
    folder
    placed_by_user { folder.created_by_user }
  end
end
