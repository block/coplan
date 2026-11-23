require "rails_helper"

RSpec.describe Coplan::DispatchNotificationJob, type: :job do
  it "passes a persisted notification to installed delivery adapters" do
    notification = create(:notification)
    handler = double("delivery handler")
    allow(handler).to receive(:call)
    Coplan.configuration.notification_delivery_handlers << handler

    described_class.perform_now(notification.id)

    expect(handler).to have_received(:call).with(notification)
  ensure
    Coplan.configuration.notification_delivery_handlers.delete(handler)
  end
end
