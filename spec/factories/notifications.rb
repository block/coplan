FactoryBot.define do
  factory :notification, class: "Coplan::Notification" do
    user { association(:coplan_user) }
    plan
    comment_thread { association(:comment_thread, plan: plan) }
    reason { "new_comment" }
  end
end
