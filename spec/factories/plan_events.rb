FactoryBot.define do
  factory :plan_event, class: "CoPlan::PlanEvent" do
    plan
    actor_type { "human" }
    event_type { "status_changed" }
    field { "status" }
    before_value { "considering" }
    after_value { "developing" }
    metadata { {} }

    trait :title_changed do
      event_type { "title_changed" }
      field { "title" }
      before_value { "Old title" }
      after_value { "New title" }
    end

    trait :tag_added do
      event_type { "tag_added" }
      field { "tags" }
      before_value { nil }
      after_value { "payments" }
    end

    trait :reference_added do
      event_type { "reference_added" }
      field { "references" }
      before_value { nil }
      after_value { "https://github.com/squareup/example" }
      metadata { { "title" => "Example repo", "reference_type" => "repository" } }
    end

    trait :system do
      actor_type { "system" }
      actor_id { nil }
    end
  end
end
