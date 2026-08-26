require "rails_helper"

RSpec.describe CoPlan::WakeWebhookJob, type: :job do
  include ActiveJob::TestHelper

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

  it "pins the connection to the address the policy vetted" do
    # The test env's permissive custom policy vets URIs, not addresses, so
    # exercise the engine default: resolve once, connect to that answer.
    original = CoPlan.configuration.wake_url_policy
    CoPlan.configuration.wake_url_policy = nil
    allow(Resolv).to receive(:getaddresses).with("agents.example.com").and_return([ "93.184.216.34" ])

    http = instance_double(Net::HTTP)
    response = instance_double(Net::HTTPResponse, code: "204")
    allow(http).to receive(:request).and_return(response)
    captured_options = nil
    allow(Net::HTTP).to receive(:start) { |*_args, **opts, &blk| captured_options = opts; blk.call(http) }

    described_class.new.perform(agent_session_id: session.id, agent_event_id: event.id)

    # A rebinding host could answer the policy check publicly and the
    # connection privately; pinning closes that window.
    expect(captured_options[:ipaddr]).to eq("93.184.216.34")
  ensure
    CoPlan.configuration.wake_url_policy = original
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

  # The URL can carry a capability token in its path, and DeliveryFailed
  # messages land in logs and solid_queue_failed_executions.
  it "keeps the wake URL out of error messages" do
    expect { deliver(code: "503") }.to raise_error(described_class::DeliveryFailed) do |error|
      expect(error.message).not_to include("agents.example.com")
      expect(error.message).not_to include("/hooks/wake")
    end
  end

  it "wraps a connection torn down mid-response, not just clean refusals" do
    allow(Net::HTTP).to receive(:start).and_raise(EOFError)

    expect {
      described_class.new.perform(agent_session_id: session.id, agent_event_id: event.id)
    }.to raise_error(described_class::DeliveryFailed) do |error|
      expect(error.message).not_to include("agents.example.com")
    end
  end

  it "skips (without retrying) a URL the egress policy refuses" do
    session; event # materialize before the stub — registration passed, policy tightened since
    allow(CoPlan::WakeUrlPolicy).to receive(:vetted_addresses).and_return(nil)

    expect(Net::HTTP).not_to receive(:start)
    expect {
      described_class.new.perform(agent_session_id: session.id, agent_event_id: event.id)
    }.not_to raise_error
  end

  it "resets the failure count on a successful delivery" do
    session.update!(wake_failures_count: 2)

    deliver

    expect(session.reload.wake_failures_count).to eq(0)
  end

  describe "the dead-URL circuit breaker" do
    def exhaust_retries
      http = instance_double(Net::HTTP)
      response = instance_double(Net::HTTPResponse, code: "503")
      allow(Net::HTTP).to receive(:start) { |*_args, **_opts, &blk| blk.call(http) }
      allow(http).to receive(:request).and_return(response)

      perform_enqueued_jobs do
        described_class.perform_later(agent_session_id: session.id, agent_event_id: event.id)
      end
    end

    it "counts an exhausted retry run without unregistering yet" do
      exhaust_retries

      expect(session.reload.wake_failures_count).to eq(1)
      expect(session.wake_url).to be_present
    end

    it "unregisters a URL that keeps eating whole retry ladders" do
      session.update!(wake_failures_count: described_class::MAX_EXHAUSTIONS - 1)

      exhaust_retries

      session.reload
      expect(session.wake_url).to be_nil
      expect(session.wake_secret).to be_nil
    end
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
