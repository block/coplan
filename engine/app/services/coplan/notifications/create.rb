module CoPlan
  module Notifications
    class Create
      def self.call(comment_thread:, actor_id:, comment: nil, reason:)
        new(comment_thread:, actor_id:, comment:, reason:).call
      end

      def initialize(comment_thread:, actor_id:, comment: nil, reason:)
        @comment_thread = comment_thread
        @actor_id = actor_id
        @comment = comment
        @reason = reason
      end

      def call
        publish_agent_events

        subscriber_ids = compute_subscribers
        subscriber_ids.delete(@actor_id)
        return if subscriber_ids.empty?

        subscriber_ids.each do |user_id|
          Notification.create!(
            user_id: user_id,
            plan_id: @comment_thread.plan_id,
            comment_thread_id: @comment_thread.id,
            comment_id: @comment&.id,
            reason: @reason
          )
        end

        broadcast_badge_updates(subscriber_ids)
      end

      private

      # Every comment/thread write path already funnels through this
      # service, so it doubles as the choke point for the agent event
      # inbox. Human notification fan-out below is unchanged; agents get
      # their own recipients (sessions on the plan), and @actor_id — the
      # api token id for token-authenticated callers — suppresses an
      # agent being woken by its own activity.
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
          actor_id: @actor_id,
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

      def broadcast_badge_updates(subscriber_ids)
        counts = Notification.where(user_id: subscriber_ids).unread.group(:user_id).count
        subscriber_ids.each do |user_id|
          Broadcaster.update_to(
            "coplan_notifications:#{user_id}",
            target: "inbox-badge",
            html: (counts[user_id] || 0).to_s
          )
        end
      end
    end
  end
end
