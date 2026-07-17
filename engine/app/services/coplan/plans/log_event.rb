module CoPlan
  module Plans
    # Single entry point for recording a metadata mutation on a plan.
    #
    # Centralizing this means every mutation path uses the same shape (actor,
    # event_type, before/after, optional field name + metadata) and we test
    # the contract once instead of per call site. Returns the persisted
    # PlanEvent record, or nil if `before` and `after` are equal (which is a
    # common case for "save without actually changing anything").
    #
    # Usage:
    #
    #   Plans::LogEvent.call(
    #     plan: plan,
    #     actor: current_user,
    #     event_type: "published",
    #     field: "visibility",
    #     before: "draft",
    #     after: "published"
    #   )
    #
    # For events without a meaningful before/after (e.g. a reference being
    # added), pass nil for the side that doesn't apply.
    class LogEvent
      def self.call(**kwargs)
        new(**kwargs).call
      end

      def initialize(plan:, actor:, event_type:, field: nil, before: nil, after: nil, metadata: {}, actor_type: nil, actor_id: nil)
        @plan = plan
        @actor = actor
        @event_type = event_type.to_s
        @field = field&.to_s
        @before = stringify(before)
        @after = stringify(after)
        @metadata = metadata || {}
        @actor_type_override = actor_type&.to_s
        @actor_id_override = actor_id
      end

      def call
        # No-op when nothing changed. Callers can fire on every save without
        # worrying about whether the value actually moved — keeps call sites
        # short and predictable.
        return nil if @before == @after && %w[status_changed title_changed plan_type_changed moved_to_folder].include?(@event_type)

        PlanEvent.create!(
          plan: @plan,
          actor_id: actor_id,
          actor_type: actor_type,
          event_type: @event_type,
          field: @field || default_field_for(@event_type),
          before_value: @before,
          after_value: @after,
          metadata: @metadata
        )
      end

      private

      def actor_id
        return @actor_id_override unless @actor_id_override.nil?
        @actor.respond_to?(:id) ? @actor.id : nil
      end

      # Mirror PlanVersion's actor model: prefer "human" when we have a user,
      # otherwise treat as a system event (e.g. backfill jobs). API callers
      # authenticating via bearer token should pass an explicit `actor_type`
      # ("local_agent") so agent-driven metadata changes aren't attributed to
      # the token owner as if they were human edits.
      def actor_type
        return @actor_type_override if @actor_type_override.present?
        @actor.present? ? "human" : "system"
      end

      def default_field_for(event_type)
        case event_type
        when "published", "archived", "unarchived" then "visibility"
        when "status_changed" then "status"
        when "title_changed" then "title"
        when "plan_type_changed" then "plan_type"
        when "tag_added", "tag_removed" then "tags"
        when "reference_added", "reference_removed" then "references"
        when "attachment_added", "attachment_removed" then "attachments"
        when "comment_deleted" then "comments"
        when "moved_to_folder" then "folder"
        end
      end

      def stringify(value)
        value.nil? ? nil : value.to_s
      end
    end
  end
end
