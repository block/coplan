require "rails_helper"

RSpec.describe CoPlan::AgentSession, type: :model do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:api_token) { CoPlan::ApiToken.create_with_raw_token(user: user, name: "agent", agent_name: "Claude").first }

  def session(state:, last_activity_at:)
    described_class.create!(
      plan: plan, api_token: api_token, agent_name: "Claude",
      state: state, last_activity_at: last_activity_at
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
end
