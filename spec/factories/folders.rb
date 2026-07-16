FactoryBot.define do
  factory :folder, class: "CoPlan::Folder" do
    sequence(:name) { |n| "Folder #{n}" }
    created_by_user { association(:coplan_user) }
  end
end
