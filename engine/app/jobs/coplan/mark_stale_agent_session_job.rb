module CoPlan
  # Scheduled at wake time (AgentSession#wake!). If the session hasn't
  # emitted any activity since that wake, the pill would be a lie — flip
  # it to stale so the UI stops showing "Waking…" for an agent that never
  # showed up.
  class MarkStaleAgentSessionJob < ApplicationJob
    def perform(agent_session_id:, woken_at:)
      session = AgentSession.find_by(id: agent_session_id)
      return unless session
      return unless session.state == "pending"

      # Any activity after the wake means the agent reacted; leave it be.
      return if session.last_activity_at.present? && session.last_activity_at > Time.iso8601(woken_at)

      session.transition!("stale")
    end
  end
end
