require "rails_helper"

RSpec.describe CoPlan::AgentEvents::Publish do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:watcher_token) { create(:api_token, user: user, agent_name: "Amp") }
  let(:recipient_token) { create(:api_token, user: user, agent_name: "Claude") }

  before do
    CoPlan::AgentSession.create!(plan: plan, api_token: watcher_token, state: "watching", agent_name: "Amp")
  end

  def publish(**options)
    described_class.call(plan: plan, event_type: "session.commit_failed", payload: { "reason" => "conflict" }, **options)
  end

  describe "with recipient_token_id" do
    it "delivers to a token with no session on the plan, and to no one else" do
      allow(CoPlan::AgentEventBus).to receive(:signal)

      expect { publish(recipient_token_id: recipient_token.id) }
        .to change { CoPlan::AgentEvent.count }.by(1)

      event = CoPlan::AgentEvent.sole
      expect(event.api_token_id).to eq(recipient_token.id)
      expect(event.payload).to include("plan_title" => plan.title, "reason" => "conflict")
      expect(CoPlan::AgentEventBus).to have_received(:signal).with(recipient_token.id).once
      expect(CoPlan::AgentEventBus).not_to have_received(:signal).with(watcher_token.id)
    end

    it "wakes the recipient's own session on the plan" do
      allow(CoPlan::WakeWebhookJob).to receive(:perform_later)
      session = CoPlan::AgentSession.create!(
        plan: plan, api_token: recipient_token, state: "complete", agent_name: "Claude",
        wake_url: "https://agents.example.com/hooks/wake", wake_secret: "s3cret"
      )

      publish(recipient_token_id: recipient_token.id)

      event = CoPlan::AgentEvent.sole
      expect(event.api_token_id).to eq(recipient_token.id)
      expect(CoPlan::WakeWebhookJob).to have_received(:perform_later)
        .with(agent_session_id: session.id, agent_event_id: event.id).once
    end

    it "skips a revoked token" do
      recipient_token.update!(revoked_at: 1.minute.ago)

      expect { publish(recipient_token_id: recipient_token.id) }
        .not_to change { CoPlan::AgentEvent.count }
    end

    it "skips an expired token" do
      recipient_token.update!(expires_at: 1.minute.ago)

      expect { publish(recipient_token_id: recipient_token.id) }
        .not_to change { CoPlan::AgentEvent.count }
    end

    it "skips an id that names no token" do
      expect { publish(recipient_token_id: user.id) }
        .not_to change { CoPlan::AgentEvent.count }
    end
  end

  describe "without recipient_token_id" do
    it "fans out to every session on the plan except the actor's" do
      CoPlan::AgentSession.create!(plan: plan, api_token: recipient_token, state: "watching", agent_name: "Claude")

      publish(actor_token_id: recipient_token.id)

      expect(CoPlan::AgentEvent.pluck(:api_token_id)).to eq([ watcher_token.id ])
    end
  end
end
