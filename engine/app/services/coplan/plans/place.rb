module CoPlan
  module Plans
    # Files a plan in (or removes it from) a folder — the single write
    # path for placements, shared by the web workspace and the API so
    # upsert semantics and the audit trail never diverge.
    #
    # A plan sits in exactly one folder of one library, so this is always
    # a move: filing it again relocates it, in or across libraries, and a
    # nil folder drops it back to its author's library root.
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
        # Filing means the destination; unfiling means wherever it is now.
        # `plan.library` falls back to the author's library for a plan that
        # isn't filed anywhere, so this is never nil.
        @library = library || folder&.library || plan.library
        @actor_type = actor_type
        @agent_name = agent_name
        @api_token_id = api_token_id
        @run_id = run_id
        @event_metadata = event_metadata || {}
      end

      def call
        unless @library.writable_by?(@actor)
          return Result.new(error: "You can only organize a library you own")
        end
        unless may_move?
          return Result.new(error: "You can only move plans you wrote")
        end
        if @folder && @folder.library_id != @library.id
          return Result.new(error: "Folder belongs to a different library")
        end
        placement = @plan.placement
        old_path = placement&.folder&.path
        # Captured before the write: afterwards the plan resolves through
        # its new placement and the old path is gone.
        old_url_path = @plan.url_path

        if @folder.nil?
          return Result.new(placement: nil) if placement.nil?

          placement.destroy!
          @plan.reload_placement
          reslug(old_url_path, nil)
          log_move(old_path, nil)
          return Result.new(placement: nil)
        end

        # Filing requires the plan to be listable for you — an unlisted
        # draft someone linked you can be read, but filing it into a
        # browsable library would surface what its author hasn't published.
        unless PlanPolicy.new(@actor, @plan).listed?
          return Result.new(error: "Only published plans (or your own drafts) can be filed")
        end

        if placement
          return Result.new(placement:) if placement.folder_id == @folder.id

          placement.update!(folder: @folder, library: @folder.library, placed_by_user: @actor)
        else
          placement = @library.placements.create!(
            plan: @plan, folder: @folder, placed_by_user: @actor
          )
        end
        @plan.reload_placement
        reslug(old_url_path, @folder)
        log_move(old_path, @folder.path)
        Result.new(placement:)
      rescue ActiveRecord::RecordInvalid => e
        Result.new(error: e.record.errors.full_messages.join(", "))
      rescue ActiveRecord::RecordNotUnique
        # Two concurrent files of the same plan raced past the read; the
        # unique plan_id index caught it. Retry once — the placement now
        # exists, so this becomes a plain move.
        raise if @retried_unique
        @retried_unique = true
        @plan.reload_placement
        retry
      end

      private

      # Filing is a move of the document, not curation of a personal
      # shelf, so it takes authority on both sides: write access to the
      # destination library (checked above) and a claim on the plan where
      # it sits now. Authors always qualify; otherwise you must control
      # the library it's currently in — which is what will let a team
      # reorganize its own library without letting anyone walk off with
      # someone else's document.
      def may_move?
        return true if @plan.created_by_user_id == @actor.id

        current = @plan.placement&.library
        current.present? && current.writable_by?(@actor)
      end

      # A plan's slug depends on where it sits — "LiveOrder Cart Roadmap"
      # is `cart-roadmap` inside "LiveOrder" and `liveorder-cart-roadmap`
      # anywhere else — so a move re-derives it and leaves an alias at the
      # old URL.
      def reslug(old_url_path, folder)
        AssignSlug.call(plan: @plan, folder: folder, previous_path: old_url_path,
          record_alias: @plan.published?)
        @plan.save! if @plan.changed?
      end

      # Two audit trails, one write path. The plan-side event only fires
      # for the author — someone else reorganizing a shared library isn't
      # an event in the plan's own history. The library-side event always
      # fires: every rearrangement is part of that library's audit log.
      #
      # A move that crosses libraries logs only the destination. Not
      # reachable today (one library per owner, so there's nowhere else to
      # move to); when team libraries land, the source library wants its
      # own "plan_removed" event here.
      def log_move(old_path, new_path)
        return if old_path == new_path

        Libraries::LogEvent.call(
          library: @library,
          actor: @actor,
          actor_type: @actor_type,
          agent_name: @agent_name,
          api_token_id: @api_token_id,
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
