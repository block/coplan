FactoryBot.define do
  factory :coplan_web_push_subscription, class: "CoPlan::WebPushSubscription" do
    user { association :coplan_user }
    sequence(:endpoint) { |n| "https://fcm.googleapis.com/fcm/send/test-#{n}" }
    p256dh_key { "BLc4xRzKlKOR_1mfH-7sa-XYqI_3rExample256dhKeyPlaceholderValueHere" }
    auth_key { "tBHItJI5svbpez7KI4CCXg" }
    user_agent { "Mozilla/5.0 (Test)" }
  end
end
