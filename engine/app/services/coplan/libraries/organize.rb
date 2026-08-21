module CoPlan
  module Libraries
    # Executes a batch of organization operations against one library — the
    # bulk write path behind POST /api/v1/libraries/:id/organize, built for
    # agents reorganizing a whole shelf in one round trip.
    #
    # Operations (each a hash with an "op" key):
    #
    #   { op: "create_folder",   path:, description: }
    #   { op: "rename_folder",   folder_path:|folder_id:, name: }
    #   { op: "describe_folder", folder_path:|folder_id:, description: }
    #   { op: "move_folder",     folder_path:|folder_id:, new_parent_path:|new_parent_id: }  (blank → root)
    #   { op: "delete_folder",   folder_path:|folder_id: }                                   (must be empty)
    #   { op: "move",            plan_id:, folder_path:|folder_id: }                         (blank dest → unfile)
    #   { op: "move_many",       plan_ids: [...], folder_path:|folder_id: }
    #   { op: "move_by_tag",     tag:, folder_path:|folder_id:, scope: "library"|"visible" }
    #
    # `from_library_id` on the move ops is accepted and ignored — old
    # callers still send it. A plan is filed in exactly one place, so
    # filing it somewhere new already takes it out of where it was; there
    # is no source side to name. Plans::Place checks the authority that
    # used to need naming (see its `may_move?`).
    #
    # Each operation is atomic (a savepoint): a failed op rolls itself back
    # and reports an error while the rest of the batch proceeds. With
    # `dry_run: true` the whole batch runs inside a transaction that is
    # rolled back at the end — the results describe exactly what *would*
    # happen, which is what lets an agent propose a reorganization for human
    # sign-off before applying it.
    #
    # Every applied change is audited through Libraries::LogEvent /
    # Plans::Place, carrying actor_type so the log distinguishes humans from
    # agents.
    class Organize
      MAX_OPERATIONS = 100
      # Per move_many op — one grouped move should classify a whole batch,
      # not smuggle in an unbounded transaction.
      MAX_PLANS_PER_MOVE = 500

      # Raised by op handlers to fail the current op: rolls back that op's
      # savepoint and becomes its error result. Never escapes the service.
      class OpError < StandardError; end

      Result = Struct.new(:results, :error, :dry_run, :run_id, keyword_init: true) do
        def success? = error.nil?
      end

      # `actor_label` names the credential behind the actor (e.g. the API
      # token's name) so the audit log can distinguish which agent session
      # did the work, not just that "a local_agent" did.
      def self.call(library:, actor:, operations:, actor_type: nil, actor_label: nil, agent_name: nil, api_token_id: nil, dry_run: false)
        new(library:, actor:, operations:, actor_type:, actor_label:, agent_name:, api_token_id:, dry_run:).call
      end

      def initialize(library:, actor:, operations:, actor_type: nil, actor_label: nil, agent_name: nil, api_token_id: nil, dry_run: false)
        @library = library
        @actor = actor
        @operations = operations
        @actor_type = actor_type
        @actor_label = actor_label
        @agent_name = agent_name
        @api_token_id = api_token_id
        @dry_run = !!dry_run
        # One id groups every audit event this call writes — a 2,000-move
        # run reads as one entry in the log, filterable via ?run_id=.
        @run_id = SecureRandom.uuid
      end

      def call
        unless @library.writable_by?(@actor)
          return Result.new(error: "You can only organize a library you can write to")
        end
        unless @operations.is_a?(Array) && @operations.any?
          return Result.new(error: "operations must be a non-empty array")
        end
        if @operations.size > MAX_OPERATIONS
          return Result.new(error: "Too many operations (max #{MAX_OPERATIONS} per request)")
        end

        results = nil
        ActiveRecord::Base.transaction do
          results = @operations.each_with_index.map { |op, index| perform(normalize(op), index) }
          raise ActiveRecord::Rollback if @dry_run
        end
        Result.new(results: results, dry_run: @dry_run, run_id: @run_id)
      end

      private

      def normalize(op)
        hash = if op.respond_to?(:to_unsafe_h)
          op.to_unsafe_h
        elsif op.respond_to?(:to_h)
          op.to_h
        else
          {} # malformed entry → dispatch reports "Unknown op nil"
        end
        hash.with_indifferent_access
      end

      # Each op runs in its own savepoint: raising out of it (OpError,
      # RecordInvalid) undoes only that op, and the rescue below turns the
      # exception into the op's error result so the batch keeps going.
      def perform(op, index)
        base = { index: index, op: op[:op] }
        outcome = ActiveRecord::Base.transaction(requires_new: true) { dispatch(op) }
        base.merge(outcome)
      rescue OpError => e
        base.merge(status: "error", error: e.message)
      rescue ActiveRecord::RecordInvalid => e
        base.merge(status: "error", error: e.record.errors.full_messages.join(", "))
      end

      def dispatch(op)
        case op[:op]
        when "create_folder" then create_folder(op)
        when "rename_folder" then rename_folder(op)
        when "describe_folder" then describe_folder(op)
        when "move_folder" then move_folder(op)
        when "delete_folder" then delete_folder(op)
        when "move" then move_plan(op)
        when "move_many" then move_many(op)
        when "move_by_tag" then move_by_tag(op)
        else
          raise OpError, "Unknown op #{op[:op].inspect}. Valid ops: create_folder, rename_folder, describe_folder, move_folder, delete_folder, move, move_many, move_by_tag"
        end
      end

      def ok(**details)
        { status: "ok" }.merge(details)
      end

      # --- folder ops ---

      def create_folder(op)
        created = []
        folder = Folder.find_or_create_by_path!(
          op[:path], library: @library, created_by_user: @actor, created: created
        )
        raise OpError, "path is required" unless folder

        log_created_folders(created)
        describe!(folder, op[:description]) if op[:description].present?
        ok(folder_id: folder.id, path: folder.path, created_paths: created.map(&:path))
      end

      def rename_folder(op)
        folder = resolve_folder!(op)
        old_path = folder.path
        folder.update!(name: op[:name])
        log!(
          event_type: "folder_renamed", folder: folder,
          before: old_path, after: folder.path
        )
        ok(folder_id: folder.id, path: folder.path)
      end

      def describe_folder(op)
        folder = resolve_folder!(op)
        describe!(folder, op[:description].to_s)
        ok(folder_id: folder.id, path: folder.path, description: folder.description)
      end

      def move_folder(op)
        folder = resolve_folder!(op)
        parent = nil
        if op[:new_parent_id].present? || op[:new_parent_path].present?
          parent = resolve_folder(folder_id: op[:new_parent_id], folder_path: op[:new_parent_path])
          raise OpError, "Unknown destination folder" unless parent
        end
        old_path = folder.path
        folder.update!(parent: parent)
        log!(
          event_type: "folder_moved", folder: folder,
          before: old_path, after: folder.path
        )
        ok(folder_id: folder.id, path: folder.path)
      end

      def delete_folder(op)
        folder = resolve_folder!(op)
        path = folder.path
        unless folder.destroy
          raise OpError, folder.errors.full_messages.join(", ")
        end
        log!(
          event_type: "folder_deleted", before: path,
          metadata: { folder_name: folder.name }
        )
        ok(path: path)
      end

      # --- plan ops ---

      def move_plan(op)
        plan = find_visible_plan!(op[:plan_id])
        folder = resolve_destination(op)
        place!(plan, folder)
        ok(plan_id: plan.id, plan_title: plan.title, path: folder&.path)
      end

      # The grouped form of `move`: one destination, many plans — so a mass
      # classification is ~one op per target folder, not one op per plan.
      # Tolerant like move_by_tag: each plan gets its own savepoint, so one
      # failure (or a half-completed cross-library transfer) rolls back that
      # plan alone and lands in `failed` while the rest proceed.
      def move_many(op)
        ids = Array(op[:plan_ids]).map(&:to_s).reject(&:blank?).uniq
        raise OpError, "plan_ids is required" if ids.empty?
        if ids.size > MAX_PLANS_PER_MOVE
          raise OpError, "Too many plan_ids (max #{MAX_PLANS_PER_MOVE} per op)"
        end

        folder = resolve_destination(op) # nil → unfile
        moved = []
        failed = []
        ids.each do |plan_id|
          ActiveRecord::Base.transaction(requires_new: true) do
            plan = find_visible_plan!(plan_id)
            place!(plan, folder)
            moved << { plan_id: plan.id, plan_title: plan.title }
          end
        rescue OpError => e
          failed << { plan_id: plan_id, error: e.message }
        end
        ok(path: folder&.path, moved_count: moved.size, moved: moved, failed: failed)
      end

      def move_by_tag(op)
        raise OpError, "tag is required" if op[:tag].blank?

        folder = resolve_destination(op)
        raise OpError, "move_by_tag requires a destination folder" if folder.nil?

        moved = []
        failed = []
        plans_for_tag(op).find_each do |plan|
          result = Plans::Place.call(
            plan: plan, folder: folder, actor: @actor, library: @library,
            actor_type: @actor_type, agent_name: @agent_name, api_token_id: @api_token_id, run_id: @run_id, event_metadata: event_metadata
          )
          if result.success?
            moved << { plan_id: plan.id, plan_title: plan.title }
          else
            failed << { plan_id: plan.id, plan_title: plan.title, error: result.error }
          end
        end
        ok(path: folder.path, moved_count: moved.size, moved: moved, failed: failed)
      end

      # scope "library" (default): plans already shelved in this library.
      # scope "visible": every active plan the actor can list with this tag
      # — the "pull everything tagged X onto my shelf" mode.
      def plans_for_tag(op)
        scoped = Plan.visible_to(@actor).with_tag(op[:tag])
        if op[:scope].to_s == "visible"
          scoped.active
        else
          scoped.joins(:placement).where(coplan_plan_placements: { library_id: @library.id })
        end
      end

      # --- helpers ---

      def find_visible_plan!(plan_id)
        plan = Plan.find_by(id: plan_id)
        unless plan && PlanPolicy.new(@actor, plan).show?
          raise OpError, "Plan not found"
        end
        plan
      end

      def place!(plan, folder)
        result = Plans::Place.call(
          plan: plan, folder: folder, actor: @actor, library: @library,
          actor_type: @actor_type, agent_name: @agent_name, api_token_id: @api_token_id, run_id: @run_id, event_metadata: event_metadata
        )
        raise OpError, result.error unless result.success?
        result
      end

      # Every audit event this run writes carries the run id and, when the
      # caller named its credential, an actor_label (e.g. the API token
      # name) — so the log answers "which agent session?" not just "an
      # agent".
      def log!(**kwargs)
        metadata = kwargs.delete(:metadata) || {}
        Libraries::LogEvent.call(
          library: @library, actor: @actor, actor_type: @actor_type,
          agent_name: @agent_name, api_token_id: @api_token_id,
          run_id: @run_id, metadata: event_metadata.merge(metadata), **kwargs
        )
      end

      def event_metadata
        @actor_label.present? ? { actor_label: @actor_label } : {}
      end

      def resolve_folder(op)
        if op[:folder_id].present?
          @library.folders.find_by(id: op[:folder_id])
        elsif op[:folder_path].present?
          Folder.find_by_path(op[:folder_path], library: @library)
        end
      end

      def resolve_folder!(op)
        resolve_folder(op) || raise(OpError, folder_missing_message(op))
      end

      # Destination for plan moves: folder_path find-or-creates (audited),
      # folder_id must exist, blank means unfile (returns nil).
      def resolve_destination(op)
        if op[:folder_path].present?
          created = []
          folder = Folder.find_or_create_by_path!(
            op[:folder_path], library: @library, created_by_user: @actor, created: created
          )
          log_created_folders(created)
          folder
        elsif op[:folder_id].present?
          @library.folders.find_by(id: op[:folder_id]) || raise(OpError, "Unknown folder_id #{op[:folder_id].inspect}")
        end
      end

      def describe!(folder, description)
        old = folder.description
        return if old.to_s == description.to_s

        folder.update!(description: description.presence)
        log!(
          event_type: "folder_described", folder: folder,
          before: old, after: folder.description,
          metadata: { path: folder.path }
        )
      end

      def log_created_folders(folders)
        folders.each do |folder|
          log!(event_type: "folder_created", folder: folder, after: folder.path)
        end
      end

      def folder_missing_message(op)
        ref = op[:folder_path].presence || op[:folder_id].presence
        ref ? "Folder #{ref.inspect} not found" : "folder_path or folder_id is required"
      end
    end
  end
end
