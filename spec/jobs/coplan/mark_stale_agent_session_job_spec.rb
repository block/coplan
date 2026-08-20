require "rails_helper"

RSpec.describe CoPlan::MarkStaleAgentSessionJob, type: :job do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:token) { CoPlan::ApiToken.create_with_raw_token(user: user, name: "agent", agent_name: "Claude").first }

  def session(state:, last_activity_at:)
    CoPlan::AgentSession.create!(
      plan: plan, api_token: token, agent_name: "Claude",
      state: state, last_activity_at: last_activity_at
    )
  end

  it "flips a pending session nothing answered to stale" do
    record = session(state: "pending", last_activity_at: 1.minute.ago)

    described_class.new.perform(agent_session_id: record.id, woken_at: record.last_activity_at.iso8601(6))

    expect(record.reload.state).to eq("stale")
  end

  it "leaves a session the agent answered after the wake" do
    record = session(state: "pending", last_activity_at: 1.minute.ago)
    woken_at = record.last_activity_at.iso8601(6)
    record.update!(last_activity_at: Time.current)

    described_class.new.perform(agent_session_id: record.id, woken_at: woken_at)

    expect(record.reload.state).to eq("pending")
  end

  # Regression: the column is datetime(6). A second-truncated woken_at
  # made the wake's own timestamp read as "activity after the wake"
  # whenever the wake landed mid-second — the job never fired, and the
  # 30-second promise behind the pending pill was a dead letter.
  it "fires even when the wake landed mid-second" do
    wake_time = Time.zone.parse("2026-08-20 12:00:00.654321")
    record = session(state: "pending", last_activity_at: wake_time)

    # With plain .iso8601 this argument would arrive as 12:00:00 — strictly
    # before the stored .654321, making the wake's own timestamp read as
    # "activity after the wake" and the early return swallow the job.
    described_class.new.perform(agent_session_id: record.id, woken_at: wake_time.iso8601(6))

    expect(record.reload.state).to eq("stale")
  end

  it "leaves sessions that already moved on" do
    record = session(state: "active", last_activity_at: 1.minute.ago)

    described_class.new.perform(agent_session_id: record.id, woken_at: record.last_activity_at.iso8601(6))

    expect(record.reload.state).to eq("active")
  end

  it "tolerates the session being gone" do
    expect {
      described_class.new.perform(agent_session_id: 0, woken_at: Time.current.iso8601(6))
    }.not_to raise_error
  end

  it "is scheduled by wake! with a full-precision timestamp" do
    record = session(state: "watching", last_activity_at: Time.zone.parse("2026-08-20 12:00:00.654321"))

    expect(CoPlan::MarkStaleAgentSessionJob).to receive(:set).with(wait: CoPlan::AgentSession::STALE_AFTER) do
      double.tap do |scheduled|
        expect(scheduled).to receive(:perform_later) do |agent_session_id:, woken_at:|
          expect(agent_session_id).to eq(record.id)
          # Microseconds must survive the trip into job arguments, or the
          # comparison against a datetime(6) column silently breaks.
          expect(Time.iso8601(woken_at)).to eq(record.reload.last_activity_at)
        end
      end
    end

    record.wake!
  end
end
