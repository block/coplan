FactoryBot.define do
  factory :comment do
    comment_thread
    organization { comment_thread.organization }
    author_type { "human" }
    author_id { association(:user, organization: organization).id }
    body_markdown { "A comment body." }
  end
end
