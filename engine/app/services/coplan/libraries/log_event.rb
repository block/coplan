module CoPlan
  module Libraries
    # Single entry point for recording an organization mutation on a library
    # — the library-side sibling of Plans::LogEvent. Every path that files,
    # moves, or removes a placement, or mutates a folder, goes through here
    # so the audit trail (who, what, where, when, human-or-agent) never
    # diverges between the web UI, the API, and bulk organize operations.
    #
    # `before` / `after` are folder paths (nil for "unfiled"). Pass the plan
    # and/or folder involved; titles and names are denormalized into
    # metadata so events stay readable after the plan or folder is deleted.
    class LogEvent
      def self.call(**kwargs)
        new(**kwargs).call
      end

      def initialize(library:, actor:, event_type:, plan: nil, folder: nil,
        before: nil, after: nil, metadata: {}, actor_type: nil, agent_name: nil,
        api_token_id: nil, run_id: nil)
        @library = library
        @actor = actor
        @event_type = event_type.to_s
        @plan = plan
        @folder = folder
        @before = before&.to_s
        @after = after&.to_s
        @metadata = metadata || {}
        @actor_type_override = actor_type&.to_s
        @agent_name = agent_name
        @api_token_id = api_token_id
        @run_id = run_id
      end

      def call
        LibraryEvent.create!(
          library: @library,
          actor_id: @actor&.id,
          actor_type: actor_type,
          agent_name: @agent_name,
          api_token_id: @api_token_id,
          event_type: @event_type,
          plan_id: @plan&.id,
          folder_id: @folder&.id,
          run_id: @run_id,
          before_value: @before,
          after_value: @after,
          metadata: default_metadata.merge(@metadata)
        )
      end

      private

      # Same defaulting as Plans::LogEvent: a user present means human unless
      # the caller says otherwise (API bearer tokens pass "local_agent").
      def actor_type
        return @actor_type_override if @actor_type_override.present?
        @actor.present? ? "human" : "system"
      end

      def default_metadata
        meta = {}
        meta[:plan_title] = @plan.title if @plan
        meta[:folder_name] = @folder.name if @folder
        meta
      end
    end
  end
end
