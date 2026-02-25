class CommitExpiredSessionJob < ApplicationJob
  queue_as :default

  def perform(session_id:)
    session = EditSession.find_by(id: session_id)
    return unless session  # Session was deleted

    # Only auto-commit if still open
    return unless session.open?

    if session.has_operations?
      Plans::CommitSession.call(
        session: session,
        change_summary: session.change_summary || "Auto-committed expired session"
      )
    else
      session.update!(status: "expired", committed_at: Time.current)
    end
  rescue Plans::CommitSession::SessionConflictError, Plans::CommitSession::StaleSessionError, Plans::OperationError => e
    # Conflict during auto-commit — mark session as failed
    session.update!(status: "failed", change_summary: "Auto-commit failed: #{e.message}")
    Rails.logger.warn("CommitExpiredSessionJob failed for session #{session_id}: #{e.message}")
  end
end
