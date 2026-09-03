module CoPlan
  module Notifications
    class Create
      # Reasons that stay silent once a thread is closed. An agent working
      # a thread it then resolves used to leave a pile of unread rows
      # pointing at a hidden highlight — the reader clicked through to an
      # apparently empty plan. Human replies and mentions still notify:
      # somebody deliberately reopening a settled conversation is news.
      SILENT_ON_CLOSED_THREAD = %w[agent_response status_change].freeze

      def self.call(comment_thread:, actor_id:, comment: nil, reason:, actor_api_token_id: nil)
        new(comment_thread:, actor_id:, comment:, reason:, actor_api_token_id:).call
      end

      def initialize(comment_thread:, actor_id:, comment: nil, reason:, actor_api_token_id: nil)
        @comment_thread = comment_thread
        @actor_id = actor_id
        @comment = comment
        @reason = reason
        @actor_api_token_id = actor_api_token_id
      end

      def call
        # Agent events publish unconditionally — closed-thread silence is
        # about not nagging humans with unread rows; an agent still wants
        # the reply (and hears the close itself via thread.status_changed).
        publish_agent_events

        # Reading the status and inserting have to be one step. An agent
        # that replies and then resolves races its own reply job: check
        # open, resolve commits and sweeps, insert — and the row is unread
        # forever on a closed thread, with a push already on its way
        # (WebPushDeliveryJob doesn't re-check read state). The lock
        # reloads the thread, so either we see the close and stay silent,
        # or the close waits for us and its sweep catches these rows.
        notified_ids = @comment_thread.with_lock do
          silenced? ? [] : insert_notifications
        end

        BroadcastBadges.call(user_ids: notified_ids)
      end

      private

      def insert_notifications
        subscriber_ids = compute_subscribers
        subscriber_ids.delete(@actor_id)
        return [] if subscriber_ids.empty?

        subscriber_ids.each do |user_id|
          Notification.create!(
            user_id: user_id,
            plan_id: @comment_thread.plan_id,
            comment_thread_id: @comment_thread.id,
            comment_id: @comment&.id,
            reason: @reason
          )
        end

        subscriber_ids
      end

      # with_lock has reloaded the thread, so this reads committed state
      # rather than whatever the job loaded moments ago.
      def silenced?
        SILENT_ON_CLOSED_THREAD.include?(@reason) && @comment_thread.closed?
      end

      # Every comment/thread write path already funnels through this
      # service, so it doubles as the choke point for the agent event
      # inbox. Human notification fan-out below is unchanged; agents get
      # their own recipients (sessions on the plan). Self-wake suppression
      # keys on the acting *token* — the comment's api_token_id, or for
      # comment-less events (a resolve/discard) the token the caller
      # passed — because @actor_id holds the *human* behind the write
      # (attribution convention), and a user id must never be compared to
      # token ids.
      def publish_agent_events
        event_type =
          case @reason
          when "status_change" then "thread.status_changed"
          when "new_comment", "reply", "agent_response"
            # Notification reasons distinguish *who* spoke (a human opening
            # a thread vs an agent answering); agents care about *where* it
            # landed. Opening a thread is `created` no matter who did it.
            opens_thread? ? "comment.created" : "comment.replied"
          end
        return unless event_type

        AgentEvents::Publish.call(
          plan: @comment_thread.plan,
          event_type: event_type,
          actor_token_id: @comment&.api_token_id || @actor_api_token_id,
          comment_thread: @comment_thread,
          comment: @comment
        )
      end

      def opens_thread?
        return false unless @comment
        @comment_thread.comments.order(:id).first&.id == @comment.id
      end

      def compute_subscribers
        case @reason
        when "new_comment"
          plan_interested_party_ids
        when "reply"
          thread_participant_ids | plan_author_ids
        when "agent_response"
          Set[@comment_thread.created_by_user_id] | plan_author_ids
        when "status_change"
          Set[@comment_thread.created_by_user_id]
        else
          Set.new
        end.to_a.compact
      end

      def plan_author_ids
        plan = @comment_thread.plan
        ids = Set[plan.created_by_user_id]
        ids.merge(
          plan.plan_collaborators
            .where(role: "author")
            .pluck(:user_id)
        )
        ids
      end

      def plan_interested_party_ids
        plan_author_ids
      end

      def thread_participant_ids
        ids = Set[@comment_thread.created_by_user_id]
        ids.merge(
          @comment_thread.comments
            .where(author_type: "human")
            .where.not(author_id: nil)
            .pluck(:author_id)
            .compact
        )
        ids
      end
    end
  end
end
