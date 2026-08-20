require "rails_helper"

RSpec.describe CoPlan::WakeWebhookJob, type: :job do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:token) { create(:api_token, user: user, raw_token: "wake-test-token", agent_name: "Orb") }
  let(:session) do
    CoPlan::AgentSession.create!(
      plan_id: plan.id, api_token_id: token.id, agent_name: "Orb", state: "complete",
      wake_url: "https://agents.example.com/hooks/wake", wake_secret: "s3cret"
    )
  end
  let(:event) do
    CoPlan::AgentEvent.create!(
      api_token_id: token.id, plan_id: plan.id, event_type: "comment.created", payload: {}
    )
  end

  def deliver(code: "204")
    http = instance_double(Net::HTTP)
    response = instance_double(Net::HTTPResponse, code: code)
    captured = nil
    allow(Net::HTTP).to receive(:start) { |*_args, **_opts, &blk| blk.call(http) }
    allow(http).to receive(:request) { |req| captured = req; response }

    described_class.new.perform(agent_session_id: session.id, agent_event_id: event.id)
    captured
  end

  it "posts a signed ping, not the event payload" do
    request = deliver

    expect(request.path).to eq("/hooks/wake")
    body = JSON.parse(request.body)
    # A ping tells the agent to come pull its inbox — the payload (and its
    # authority context) stays behind the authenticated cursor API.
    expect(body.keys).to contain_exactly("event_id", "event_type", "plan_id", "inbox")
    expect(body["event_id"]).to eq(event.id)

    expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "s3cret", request.body)}"
    expect(request["X-CoPlan-Signature"]).to eq(expected)
    expect(request["X-CoPlan-Event-Id"]).to eq(event.id)
  end

  it "raises a retryable error when the receiver is unhappy" do
    expect { deliver(code: "503") }.to raise_error(described_class::DeliveryFailed)
  end

  it "skips events already processed via another transport" do
    event.update!(acked_at: Time.current)

    expect(Net::HTTP).not_to receive(:start)
    described_class.new.perform(agent_session_id: session.id, agent_event_id: event.id)
  end

  it "does nothing once the session unregistered" do
    session.update!(wake_url: nil, wake_secret: nil)

    expect(Net::HTTP).not_to receive(:start)
    described_class.new.perform(agent_session_id: session.id, agent_event_id: event.id)
  end
end
