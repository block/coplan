FactoryBot.define do
  factory :tag, class: "Coplan::Tag" do
    sequence(:name) { |n| "tag-#{n}" }
  end
end
