module CoPlan
  class CommitExpiredSessionJob < ApplicationJob
    queue_as :default

    def perform(session_id:)
      session = EditSession.find_by(id: session_id)
      return unless session  # Session was deleted

      # Only auto-commit if still open
      return unless session.open?

      if session.has_operations?
        # The session's actor_id is the API token that owned it; the version
        # should name the human behind it and the agent that acted, same as
        # a live commit through the controller.
        token = ApiToken.find_by(id: session.actor_id)
        Plans::CommitSession.call(
          session: session,
          change_summary: session.change_summary || "Auto-committed expired session",
          actor_id: token&.user_id || session.actor_id,
          agent_name: token && ApiToken.normalized_agent_name(token.agent_name.presence || token.name),
          api_token_id: token&.id
        )
      else
        session.update!(status: "expired", committed_at: Time.current)
      end
    rescue Plans::CommitSession::SessionNotOpenError
      # Session was closed concurrently (manual commit/cancel) — nothing to do
      Rails.logger.info("CommitExpiredSessionJob: session #{session_id} already closed, skipping")
    rescue Plans::CommitSession::SessionConflictError, Plans::CommitSession::StaleSessionError, Plans::OperationError => e
      # Conflict during auto-commit — mark session as failed
      session.update!(status: "failed", change_summary: "Auto-commit failed: #{e.message}")
      Rails.logger.warn("CommitExpiredSessionJob failed for session #{session_id}: #{e.message}")
    end
  end
end
