FactoryBot.define do
  factory :comment_reaction, class: "CoPlan::CommentReaction" do
    comment
    user { association(:coplan_user) }
    kind { "thumbs_up" }
  end
end
