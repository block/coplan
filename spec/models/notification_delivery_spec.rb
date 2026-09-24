require "rails_helper"

RSpec.describe CoPlan::NotificationDelivery, type: :model do
  it "tracks a channel outcome per notification" do
    delivery = create(:notification_delivery)
    expect(delivery).to be_valid
    expect { create(:notification_delivery, notification: delivery.notification) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "validates channel and status" do
    expect(build(:notification_delivery, channel: "fax")).not_to be_valid
    expect(build(:notification_delivery, status: "unknown")).not_to be_valid
  end
end
