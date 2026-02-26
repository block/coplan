FactoryBot.define do
  factory :edit_session, class: "CoPlan::EditSession" do
    plan
    actor_type { "local_agent" }
    actor_id { SecureRandom.uuid_v7 }
    base_revision { plan.current_revision }
    status { "open" }
    operations_json { [] }
    expires_at { 1.hour.from_now }

    trait :committed do
      status { "committed" }
      committed_at { Time.current }
    end

    trait :with_operations do
      operations_json { [{ "op" => "replace_exact", "old_text" => "old", "new_text" => "new" }] }
    end
  end
end
