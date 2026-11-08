module CoPlan
  class CommitExpiredSessionJob < ApplicationJob
    queue_as :default

    retry_on ActiveRecord::ActiveRecordError, wait: :polynomially_longer, attempts: 5

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
    rescue EditLease::Conflict
      # Keep the draft open and retry after the temporary document lock expires.
      self.class.set(wait: EditLease::LEASE_DURATION).perform_later(session_id: session_id)
    rescue Plans::CommitSession::SessionNotOpenError
      # Session was closed concurrently (manual commit/cancel) — nothing to do
      Rails.logger.info("CommitExpiredSessionJob: session #{session_id} already closed, skipping")
    rescue Plans::HumanEditGuard::Blocked => e
      # A person edited by hand while this session sat open, and the agent
      # that owned it never came back to read them. Auto-committing would
      # rebase an abandoned draft straight over their words with nobody in
      # the loop to notice — so the session dies instead. The operations
      # stay on the row if anyone wants to see what was lost.
      fail_session(session, reason: "human_edit_pending", error: e, summary: "Auto-commit blocked")
      Rails.logger.warn("CommitExpiredSessionJob: session #{session_id} blocked by an unread human edit")
    rescue Plans::CommitSession::SessionConflictError, Plans::CommitSession::StaleSessionError, Plans::OperationError => e
      # Conflict during auto-commit — mark session as failed
      fail_session(session, reason: e.is_a?(Plans::CommitSession::StaleSessionError) ? "stale" : "conflict", error: e, summary: "Auto-commit failed")
      Rails.logger.warn("CommitExpiredSessionJob failed for session #{session_id}: #{e.message}")
    end

    private

    # Save the terminal state and durable inbox entry together. A failed
    # publish leaves the session open for retry. Recheck under the lock so
    # duplicate jobs cannot notify twice or overwrite a concurrent commit.
    def fail_session(session, reason:, error:, summary:)
      session.with_lock(requires_new: true) do
        return unless session.open?

        session.update!(status: "failed", change_summary: "#{summary}: #{error.message}")
        notify_owner(session, reason: reason, error: error)
      end
    end

    # The agent that staged these edits believes they will land when its
    # session expires. Tell it they didn't, so it re-reads the plan and redoes
    # them instead of assuming the document says what it wrote. The session's
    # actor_id is the owner's API token id; Publish skips anything that isn't
    # an active token (a revoked owner, a cloud persona).
    def notify_owner(session, reason:, error:)
      return if session.actor_id.blank?

      plan = session.plan.reload
      AgentEvents::Publish.call(
        plan: plan,
        event_type: "session.commit_failed",
        recipient_token_id: session.actor_id,
        payload: {
          "session_id" => session.id,
          "base_revision" => session.base_revision,
          "current_revision" => plan.current_revision,
          "reason" => reason,
          "message" => error.message
        }
      )
    end
  end
end
