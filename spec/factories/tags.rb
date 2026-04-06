FactoryBot.define do
  factory :tag, class: "CoPlan::Tag" do
    sequence(:name) { |n| "tag-#{n}" }
  end
end
