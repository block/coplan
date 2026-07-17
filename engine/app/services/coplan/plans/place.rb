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

      def self.call(plan:, folder:, actor:, library: nil)
        new(plan:, folder:, actor:, library:).call
      end

      def initialize(plan:, folder:, actor:, library: nil)
        @plan = plan
        @folder = folder
        @actor = actor
        @library = library || folder&.library || actor.library
      end

      def call
        unless @library.writable_by?(@actor)
          return Result.new(error: "You can only organize your own library")
        end
        if @folder && @folder.library_id != @library.id
          return Result.new(error: "Folder belongs to a different library")
        end
        # Shelving requires the plan to be listable for you — an unlisted
        # draft someone linked you can be read, but filing it onto a
        # browsable shelf would surface what its author hasn't published.
        unless PlanPolicy.new(@actor, @plan).listed?
          return Result.new(error: "Only published plans (or your own drafts) can be shelved")
        end

        placement = @library.placements.find_by(plan_id: @plan.id)
        old_path = placement&.folder&.path

        if @folder.nil?
          return Result.new(placement: nil) if placement.nil?

          placement.destroy!
          log_move(old_path, nil)
          return Result.new(placement: nil)
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
      end

      private

      # The audit trail lives on the plan, but only for the author's own
      # library — someone else curating their shelf isn't an event in the
      # plan's history.
      def log_move(old_path, new_path)
        return unless @plan.created_by_user_id == @actor.id
        return if old_path == new_path

        LogEvent.call(
          plan: @plan,
          actor: @actor,
          event_type: "moved_to_folder",
          before: old_path,
          after: new_path
        )
      end
    end
  end
end
