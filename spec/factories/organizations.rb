FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Organization #{n}" }
    sequence(:slug) { |n| "org-#{n}" }
    allowed_email_domains { ["example.com"] }
  end
end
