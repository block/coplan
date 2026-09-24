FactoryBot.define do
  factory :notification_delivery, class: "CoPlan::NotificationDelivery" do
    notification
    channel { "slack" }
    status { "pending" }
  end
end
