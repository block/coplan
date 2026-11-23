FactoryBot.define do
  factory :notification_delivery, class: "Coplan::NotificationDelivery" do
    notification
    channel { "slack" }
    status { "pending" }
  end
end
