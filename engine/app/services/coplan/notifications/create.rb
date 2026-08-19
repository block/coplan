module CoPlan
  module Notifications
    class Create
      # Reasons that stay silent once a thread is closed. An agent working
      # a thread it then resolves used to leave a pile of unread rows
      # pointing at a hidden highlight — the reader clicked through to an
      # apparently empty plan. Human replies and mentions still notify:
      # somebody deliberately reopening a settled conversation is news.
      SILENT_ON_CLOSED_THREAD = %w[agent_response status_change].freeze

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
        return if silenced?

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

        BroadcastBadges.call(user_ids: subscriber_ids)
      end

      private

      def silenced?
        SILENT_ON_CLOSED_THREAD.include?(@reason) && @comment_thread.closed?
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
