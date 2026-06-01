require "rails_helper"

RSpec.describe CoPlan::Analytics do
  let(:received) { [] }
  let(:handler) { ->(event, payload) { received << [event, payload] } }
  let(:user) { create(:coplan_user) }

  around do |example|
    previous = CoPlan.configuration.track_event
    CoPlan.configuration.track_event = handler
    example.run
    CoPlan.configuration.track_event = previous
  end

  it "is a no-op when no handler is configured" do
    CoPlan.configuration.track_event = nil
    expect { described_class.track("foo") }.not_to raise_error
    expect(received).to be_empty
  end

  it "invokes the configured handler with event name and payload" do
    freeze_time do
      described_class.track("plan_created", user: user, plan_id: "abc", custom: "value")

      expect(received.length).to eq(1)
      event_name, payload = received.first
      expect(event_name).to eq("plan_created")
      expect(payload).to include(
        event: "plan_created",
        timestamp: Time.current.iso8601,
        user_id: user.id,
        properties: { plan_id: "abc", custom: "value" }
      )
    end
  end

  it "accepts symbol event names and stringifies them" do
    described_class.track(:plan_published, user: user)
    expect(received.first.first).to eq("plan_published")
    expect(received.first.last[:event]).to eq("plan_published")
  end

  it "sends nil user_id when no user given" do
    described_class.track("page_view")
    expect(received.first.last[:user_id]).to be_nil
  end

  it "swallows handler errors and reports them via error_reporter" do
    reported = []
    previous_reporter = CoPlan.configuration.error_reporter
    CoPlan.configuration.error_reporter = ->(exception, context) { reported << [exception, context] }
    CoPlan.configuration.track_event = ->(_event, _payload) { raise "boom" }

    expect { described_class.track("plan_created", user: user) }.not_to raise_error

    expect(reported.length).to eq(1)
    exception, context = reported.first
    expect(exception.message).to eq("boom")
    expect(context).to eq(coplan_analytics_event: "plan_created")
  ensure
    CoPlan.configuration.error_reporter = previous_reporter
  end
end
