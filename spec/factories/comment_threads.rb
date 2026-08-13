FactoryBot.define do
  factory :comment_thread, class: "CoPlan::CommentThread" do
    plan
    plan_version { plan.current_plan_version }
    created_by_user { association(:coplan_user) }
    status { "pending" }
    out_of_date { false }

    # Threads refuse anchors that don't resolve against the plan content,
    # so the anchor here is a real substring of the plan factory's default
    # content_markdown.
    trait :with_anchor do
      anchor_text { "Some content here" }
    end

    trait :with_positioned_anchor do
      anchor_text { "some anchor text" }
      anchor_start { 10 }
      anchor_end { 26 }
      anchor_revision { 1 }
    end

    trait :resolved do
      status { "resolved" }
      resolved_by_user { association(:coplan_user) }
    end
  end
end
