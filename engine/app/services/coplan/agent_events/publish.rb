module CoPlan
  module AgentEvents
    # Fans an event out to the inbox of every agent session on the plan,
    # except the actor's own (an agent should not be woken by its own
    # comment or edit). Suppression matches on the api token id — never a
    # user id, since attribution rows store the human while the token is
    # the unit of subscription.
    class Publish
      def self.call(plan:, event_type:, actor_token_id: nil, comment_thread: nil, comment: nil, payload: {})
        new(plan:, event_type:, actor_token_id:, comment_thread:, comment:, payload:).call
      end

      def initialize(plan:, event_type:, actor_token_id:, comment_thread:, comment:, payload:)
        @plan = plan
        @event_type = event_type
        @actor_token_id = actor_token_id
        @comment_thread = comment_thread
        @comment = comment
        @payload = payload
      end

      def call
        sessions = AgentSession.where(plan_id: @plan.id).includes(:api_token)
        sessions.each do |session|
          next if @actor_token_id.present? && session.api_token_id == @actor_token_id

          agent_event = AgentEvent.create!(
            api_token_id: session.api_token_id,
            plan_id: @plan.id,
            comment_thread_id: @comment_thread&.id,
            comment_id: @comment&.id,
            event_type: @event_type,
            payload: base_payload.merge(authority_payload(session)).merge(@payload)
          )
          # The event is queued for every session — inboxes are durable, so
          # a detached agent gets its backlog when it comes back. But only
          # a session with something actually attached gets woken into a
          # pill: otherwise an abandoned session is resurrected by every
          # new comment and haunts the plan forever. `wakeable?` narrows
          # that further to sessions with a real path for the wake — a
          # parked connection or a wake URL. Without one, flipping to
          # pending would start a 30-second countdown nothing can answer.
          session.wake! if session.live? && session.wakeable?

          # A wake URL is a standing subscription: it fires even when the
          # session looks finished (`complete`), because a hosted agent
          # holds no transport between turns — waking it back up is the
          # entire point of registering one. Enqueued after commit: the
          # queue lives in a separate database, so a worker can otherwise
          # pick the job up before the AgentEvent row is visible and
          # no-op the wake.
          if session.wake_url.present?
            ActiveRecord.after_all_transactions_commit do
              WakeWebhookJob.perform_later(agent_session_id: session.id, agent_event_id: agent_event.id)
            end
          end

          # Hand the event straight to any connection already waiting on
          # this token's inbox, so delivery doesn't wait for a poll tick.
          AgentEventBus.signal(session.api_token_id)
        end
      end

      private

      def base_payload
        payload = {
          "plan_title" => @plan.title,
          "plan_revision" => @plan.current_revision
        }
        if @comment_thread
          payload["thread_status"] = @comment_thread.status
          payload["anchor_text"] = @comment_thread.anchor_text
        end
        if @comment
          payload["comment_body"] = @comment.body_markdown
          payload["comment_author"] = @comment.agent_name.presence || @comment.author&.name
          payload["comment_author_type"] = @comment.author_type
        end
        payload
      end

      # How much weight the agent should give this comment. Two separate
      # questions, because they come apart: the person who wrote the plan
      # isn't necessarily the person whose agent this is, and a comment from
      # a stranger on your own plan shouldn't authorize edits the way your
      # own comment does.
      #
      #   from_principal  the commenter is the human this token belongs to
      #   from_plan_author  the commenter wrote the plan
      #   authority       "principal" → act directly
      #                   "collaborator" → acknowledge and propose in-thread
      def authority_payload(session)
        return {} unless @comment

        principal_id = session.api_token&.user_id
        # author_id holds a user id for both human and local_agent comments,
        # so an agent posting on someone's behalf carries their authority.
        author_id = @comment.author_id if @comment.author_type.in?(%w[human local_agent])
        from_principal = author_id.present? && author_id == principal_id

        {
          "from_principal" => from_principal,
          "from_plan_author" => author_id.present? && author_id == @plan.created_by_user_id,
          "authority" => from_principal ? "principal" : "collaborator"
        }
      end
    end
  end
end
