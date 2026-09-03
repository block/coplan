# This migration comes from co_plan (originally 20260820000000)
class AddWakePlumbingToAgentSessions < ActiveRecord::Migration[8.0]
  # Guarded like 20260807000000: main's schema.rb has carried leaked
  # agent-collab structure before, so never assume a clean slate.
  def change
    return unless table_exists?(:coplan_agent_sessions)

    # Evidence a connection is actually parked on this session's token —
    # SSE heartbeats and long-poll parks touch it. Distinct from
    # last_activity_at, which tracks the agent/state machine: a held
    # socket must not keep a `pending` promise alive forever.
    unless column_exists?(:coplan_agent_sessions, :last_transport_at)
      add_column :coplan_agent_sessions, :last_transport_at, :datetime
    end

    # How many wakes this session has demonstrably answered (pending →
    # an agent-driven state). Zero means the loop is unproven and the
    # pill makes no wake promise.
    unless column_exists?(:coplan_agent_sessions, :wakes_answered_count)
      add_column :coplan_agent_sessions, :wakes_answered_count, :integer, default: 0, null: false
    end

    # Webhook wake: a session may register a URL CoPlan POSTs a signed
    # "you have inbox items" ping to — the wake path for hosted agents
    # that can receive HTTP but can't hold a connection or be resumed.
    unless column_exists?(:coplan_agent_sessions, :wake_url)
      add_column :coplan_agent_sessions, :wake_url, :string
    end

    unless column_exists?(:coplan_agent_sessions, :wake_secret)
      add_column :coplan_agent_sessions, :wake_secret, :string
    end
  end
end
