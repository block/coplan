class AddWakeFailuresCountToAgentSessions < ActiveRecord::Migration[8.0]
  def change
    return unless table_exists?(:coplan_agent_sessions)
    return if column_exists?(:coplan_agent_sessions, :wake_failures_count)

    # Exhausted wake-webhook delivery runs since the last success; the
    # URL is unregistered once this crosses WakeWebhookJob::MAX_EXHAUSTIONS.
    add_column :coplan_agent_sessions, :wake_failures_count, :integer, default: 0, null: false
  end
end
