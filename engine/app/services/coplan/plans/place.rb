module CoPlan
  module Plans
    # Shelves a plan in (or removes it from) one folder of a library —
    # the single write path for placements, shared by the web workspace
    # and the API so upsert semantics and the audit trail never diverge.
    #
    # A plan sits in at most one folder per library: placing it again
    # moves the placement; a nil folder unfiles it. Placing someone
    # else's plan is first-class — the plan itself is untouched, only
    # the actor's shelf changes.
    class Place
      Result = Struct.new(:placement, :error, keyword_init: true) do
        def success? = error.nil?
      end

      # `actor_type` distinguishes humans from agents in the audit trail —
      # API callers authenticating via bearer token pass "local_agent";
      # the web UI omits it (defaults to "human" via the log services).
      # `run_id` / `event_metadata` flow into the library-side audit event
      # so bulk organize runs stay grouped and attributable (token label).
      def self.call(plan:, folder:, actor:, library: nil, actor_type: nil,
        agent_name: nil, api_token_id: nil, run_id: nil, event_metadata: {})
        new(plan:, folder:, actor:, library:, actor_type:, agent_name:, api_token_id:, run_id:, event_metadata:).call
      end

      def initialize(plan:, folder:, actor:, library: nil, actor_type: nil,
        agent_name: nil, api_token_id: nil, run_id: nil, event_metadata: {})
        @plan = plan
        @folder = folder
        @actor = actor
        @library = library || folder&.library || actor.library
        @actor_type = actor_type
        @agent_name = agent_name
        @api_token_id = api_token_id
        @run_id = run_id
        @event_metadata = event_metadata || {}
      end

      def call
        unless @library.writable_by?(@actor)
          return Result.new(error: "You can only organize your own library")
        end
        if @folder && @folder.library_id != @library.id
          return Result.new(error: "Folder belongs to a different library")
        end
        placement = @library.placements.find_by(plan_id: @plan.id)
        old_path = placement&.folder&.path

        # Removal is always allowed — you can take anything off your own
        # shelf, even if the plan has since stopped being listable to you.
        if @folder.nil?
          return Result.new(placement: nil) if placement.nil?

          placement.destroy!
          log_move(old_path, nil)
          return Result.new(placement: nil)
        end

        # Shelving requires the plan to be listable for you — an unlisted
        # draft someone linked you can be read, but filing it onto a
        # browsable shelf would surface what its author hasn't published.
        unless PlanPolicy.new(@actor, @plan).listed?
          return Result.new(error: "Only published plans (or your own drafts) can be shelved")
        end

        if placement
          return Result.new(placement:) if placement.folder_id == @folder.id

          placement.update!(folder: @folder, placed_by_user: @actor)
        else
          placement = @library.placements.create!(
            plan: @plan, folder: @folder, placed_by_user: @actor
          )
        end
        log_move(old_path, @folder.path)
        Result.new(placement:)
      rescue ActiveRecord::RecordInvalid => e
        Result.new(error: e.record.errors.full_messages.join(", "))
      rescue ActiveRecord::RecordNotUnique
        # Two concurrent shelves of the same plan raced past find_by; the
        # unique [plan_id, library_id] index caught it. Retry once — the
        # placement now exists, so this becomes a plain re-file.
        raise if @retried_unique
        @retried_unique = true
        retry
      end

      private

      # Two audit trails, one write path. The plan-side event only fires for
      # the author's own library — someone else curating their shelf isn't
      # an event in the plan's history. The library-side event always fires:
      # every rearrangement of a shelf is part of that library's audit log.
      def log_move(old_path, new_path)
        return if old_path == new_path

        Libraries::LogEvent.call(
          library: @library,
          actor: @actor,
          actor_type: @actor_type,
          event_type: library_event_type(old_path, new_path),
          plan: @plan,
          folder: @folder,
          before: old_path,
          after: new_path,
          run_id: @run_id,
          metadata: @event_metadata
        )

        return unless @plan.created_by_user_id == @actor.id

        LogEvent.call(
          plan: @plan,
          actor: @actor,
          actor_type: @actor_type,
          agent_name: @agent_name,
          api_token_id: @api_token_id,
          event_type: "moved_to_folder",
          before: old_path,
          after: new_path
        )
      end

      def library_event_type(old_path, new_path)
        if old_path.nil? then "plan_filed"
        elsif new_path.nil? then "plan_removed"
        else "plan_moved"
        end
      end
    end
  end
end
