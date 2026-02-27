FactoryBot.define do
  factory :comment, class: "CoPlan::Comment" do
    comment_thread
    author_type { "human" }
    author_id { association(:coplan_user).id }
    body_markdown { "A comment body." }
  end
end
