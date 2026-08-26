require "rails_helper"

RSpec.describe CoPlan::AgentSession, type: :model do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:api_token) { CoPlan::ApiToken.create_with_raw_token(user: user, name: "agent", agent_name: "Claude").first }

  def session(state:, last_activity_at:, **extra)
    described_class.create!(
      plan: plan, api_token: api_token, agent_name: "Claude",
      state: state, last_activity_at: last_activity_at, **extra
    )
  end

  describe ".visible" do
    # Staleness is computed at read time so a dead agent process — or a
    # job worker that never ran MarkStaleAgentSessionJob — can't leave a
    # ghost pill promising an agent that isn't coming.
    it "hides a pending session whose agent never reacted" do
      session(state: "pending", last_activity_at: 2.minutes.ago)

      expect(described_class.visible).to be_empty
    end

    it "shows a pending session that was just woken" do
      session(state: "pending", last_activity_at: 5.seconds.ago)

      expect(described_class.visible.count).to eq(1)
    end

    it "keeps an active session visible through a long turn" do
      session(state: "active", last_activity_at: 2.minutes.ago)

      expect(described_class.visible.count).to eq(1)
    end

    it "hides an active session whose process died" do
      session(state: "active", last_activity_at: 10.minutes.ago)

      expect(described_class.visible).to be_empty
    end

    it "keeps a watching session visible while its stream is alive" do
      session(state: "watching", last_activity_at: 30.seconds.ago)

      expect(described_class.visible.count).to eq(1)
    end

    it "hides a watching session once the stream stops heartbeating" do
      session(state: "watching", last_activity_at: 5.minutes.ago)

      expect(described_class.visible).to be_empty
    end

    it "hides completed sessions regardless of recency" do
      session(state: "complete", last_activity_at: 1.second.ago)

      expect(described_class.visible).to be_empty
    end
  end

  describe "#stale?" do
    it "falls back to updated_at when last_activity_at is missing" do
      record = session(state: "pending", last_activity_at: nil)

      expect(record.stale?).to be(false)
    end
  end

  describe "#display_status" do
    # Wakeability is demonstrated, never declared: until this session has
    # answered a wake, a delivery is quietly a test and the pill keeps
    # plain presence.
    it "keeps plain presence through an unproven wake" do
      record = session(state: "pending", last_activity_at: 5.seconds.ago)

      expect(record.display_status).to eq("Claude")
    end

    it "promises the wake once one has been answered before" do
      record = session(state: "pending", last_activity_at: 5.seconds.ago, wakes_answered_count: 1)

      expect(record.display_status).to eq("Waking Claude…")
    end

    it "lets only the agent's own active state claim work" do
      record = session(state: "active", last_activity_at: 5.seconds.ago)

      expect(record.display_status).to eq("Claude is working…")
    end
  end

  describe "wake proof" do
    # The one observable proof that delivery became a model turn is the
    # agent moving itself out of `pending`.
    it "counts an agent-driven exit from pending as an answered wake" do
      record = session(state: "pending", last_activity_at: 5.seconds.ago)

      record.transition!("active", detail: "reading your comment")

      expect(record.wakes_answered_count).to eq(1)
      expect(record).to be_wake_proven
    end

    it "does not count the server declaring the wake dead" do
      record = session(state: "pending", last_activity_at: 5.seconds.ago)

      record.transition!("stale")

      expect(record.wakes_answered_count).to eq(0)
    end

    it "does not count transitions that never left pending behind" do
      record = session(state: "watching", last_activity_at: 5.seconds.ago)

      record.transition!("active")

      expect(record.wakes_answered_count).to eq(0)
    end

    # Detach paths file `complete` mechanically (coplan-attach's at_exit),
    # and supervising loops re-claim `watching` on restart — neither says a
    # model turned the wake into work, so neither may prove wakeability.
    it "does not count a mechanical detach out of pending" do
      record = session(state: "pending", last_activity_at: 5.seconds.ago)

      record.transition!("complete")

      expect(record.wakes_answered_count).to eq(0)
    end

    it "does not count a watcher re-claim out of pending" do
      record = session(state: "pending", last_activity_at: 5.seconds.ago)

      record.transition!("watching")

      expect(record.wakes_answered_count).to eq(0)
    end
  end

  describe "wake_url validation" do
    around do |example|
      # The test env installs a permissive policy; these examples exercise
      # how the model consults whatever policy is configured.
      original = CoPlan.configuration.wake_url_policy
      example.run
    ensure
      CoPlan.configuration.wake_url_policy = original
    end

    it "refuses a URL the egress policy rejects" do
      CoPlan.configuration.wake_url_policy = ->(uri) { false }

      record = described_class.new(
        plan: plan, api_token: api_token, agent_name: "Claude",
        state: "complete", wake_url: "https://agents.example.com/wake"
      )

      expect(record).not_to be_valid
      expect(record.errors[:wake_url]).to be_present
    end

    it "does not re-resolve an unchanged URL on state transitions" do
      record = session(state: "pending", last_activity_at: 5.seconds.ago,
        wake_url: "https://agents.example.com/wake")
      # Policy tightens after registration: existing sessions must still be
      # able to move through their state machine (the webhook job is the
      # enforcement point at delivery time).
      CoPlan.configuration.wake_url_policy = ->(uri) { raise "resolved during transition" }

      expect { record.transition!("active") }.not_to raise_error
    end
  end

  describe "parent cleanup" do
    # Both collaboration tables FK the plan and the token; without the
    # delete_all associations, destroying either parent raises.
    it "is deleted with its plan, along with the plan's inbox rows" do
      session(state: "watching", last_activity_at: Time.current)
      CoPlan::AgentEvent.create!(api_token_id: api_token.id, plan_id: plan.id, event_type: "comment.created", payload: {})

      # The current-version self-reference has to be detached before any
      # plan can be destroyed (pre-existing, unrelated to agent rows) —
      # this example is about the agent tables not blocking the delete.
      plan.update_columns(current_plan_version_id: nil)
      expect { plan.destroy! }.not_to raise_error
      expect(described_class.where(plan_id: plan.id)).to be_empty
      expect(CoPlan::AgentEvent.where(plan_id: plan.id)).to be_empty
    end

    it "is deleted with its token, along with the token's inbox rows" do
      session(state: "watching", last_activity_at: Time.current)
      CoPlan::AgentEvent.create!(api_token_id: api_token.id, plan_id: plan.id, event_type: "comment.created", payload: {})

      expect { api_token.destroy! }.not_to raise_error
      expect(described_class.where(api_token_id: api_token.id)).to be_empty
      expect(CoPlan::AgentEvent.where(api_token_id: api_token.id)).to be_empty
    end
  end

  describe "#transport_connected?" do
    it "is true within the transport window" do
      record = session(state: "watching", last_activity_at: Time.current, last_transport_at: 30.seconds.ago)

      expect(record.transport_connected?).to be(true)
    end

    it "is false once the window lapses" do
      expect(session(state: "watching", last_activity_at: Time.current, last_transport_at: 2.minutes.ago).transport_connected?).to be(false)
    end

    it "is false without any touch at all" do
      expect(session(state: "watching", last_activity_at: Time.current).transport_connected?).to be(false)
    end
  end
end
