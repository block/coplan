require "rails_helper"

RSpec.describe CoPlan::DispatchNotificationJob, type: :job do
  it "passes a persisted notification to installed delivery adapters" do
    notification = create(:notification)
    handler = double("delivery handler")
    allow(handler).to receive(:call)
    CoPlan.configuration.notification_delivery_handlers << handler

    described_class.perform_now(notification.id)

    expect(handler).to have_received(:call).with(notification)
  ensure
    CoPlan.configuration.notification_delivery_handlers.delete(handler)
  end

  it "retries on a worker that has not enabled the adapter" do
    notification = create(:notification)
    expect { described_class.new.perform(notification.id) }
      .to raise_error(described_class::AdapterUnavailable)
  end
end
