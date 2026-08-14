module CoPlan
  module Api
    module V1
      # The agent-facing organization API. A library is a shelf (folder tree
      # + placements); this controller is how an agent learns a shelf's
      # layout in one call (show), bulk-reads what's on it (contents),
      # rearranges it (organize), and audits who rearranged it (events).
      #
      # Reads are open to any authenticated caller (counts and rows stay
      # viewer-filtered, matching library browsing on the web); the audit
      # log and all writes require write access to the library.
      class LibrariesController < BaseController
        before_action :set_library

        def index
          libraries = Library.includes(:owner).order(:created_at)
          render json: libraries.map { |library|
            {
              id: library.id,
              name: library.name,
              owner: owner_json(library),
              writable: library.writable_by?(current_user),
              mine: library.writable_by?(current_user)
            }
          }
        end

        # The map of one library: nested-by-path folder list with
        # descriptions and counts, unfiled work, top tags, and recent
        # activity. Designed so one GET gives an agent everything it needs
        # to understand the layout before organizing.
        def show
          folders = @library.folders.order(:name).to_a
          paths = Folder.paths_by_id(folders)
          counts = visible_placement_counts
          totals = subtree_totals(folders, counts)

          json = {
            id: @library.id,
            name: @library.name,
            owner: owner_json(@library),
            writable: writable?,
            folders: folders.sort_by { |f| paths[f.id].downcase }.map { |f|
              {
                id: f.id,
                name: f.name,
                description: f.description,
                path: paths[f.id],
                parent_id: f.parent_id,
                plans_count: counts.fetch(f.id, 0),
                total_plans_count: totals.fetch(f.id, 0)
              }
            },
            top_tags: top_tags_json,
            organize_instructions_url: CoPlan::Engine.routes.url_helpers.agent_instructions_organizing_path
          }
          if writable?
            json[:unfiled_count] = unfiled_plans.count
            json[:recent_activity] = @library.library_events.recent_first.includes(:actor_user).limit(10).map { |e| event_json(e) }
          end
          render json: json
        end

        # Bulk read: one compact row per shelved plan — title, summary,
        # tags, dates, location. Filters: folder_id/folder_path (+
        # recursive=true for the whole subtree), tag, unfiled=true (your
        # own unshelved plans; writable libraries only), archived=true.
        def contents
          if params[:unfiled].to_s == "true"
            return render json: { error: "unfiled=true requires write access to the library" }, status: :forbidden unless writable?
            plans = unfiled_plans.includes(:tags, :created_by_user).order(updated_at: :desc)
            return render json: {
              library_id: @library.id,
              count: plans.size,
              items: plans.map { |plan| content_row(plan, placement: nil, paths: {}) }
            }
          end

          placements = @library.placements
            .visible_to(current_user)
            .includes(:placed_by_user, plan: [ :tags, :created_by_user ])
          placements = placements.where(plan: params[:archived].to_s == "true" ? Plan.archived : Plan.active)

          if params[:folder_id].present? || params[:folder_path].present?
            folder = find_folder_param
            return render json: { error: "Folder not found" }, status: :not_found unless folder
            folder_ids = [ folder.id ]
            folder_ids += folder.descendants.map(&:id) if params[:recursive].to_s == "true"
            placements = placements.where(folder_id: folder_ids)
          end

          if params[:tag].present?
            placements = placements.where(plan_id: Plan.with_tag(params[:tag]).select(:id))
          end

          paths = Folder.paths_by_id(@library.folders.to_a)
          rows = placements.to_a.sort_by { |p| [ paths[p.folder_id].to_s.downcase, p.plan.title.to_s.downcase ] }

          limit = params[:limit].present? ? params[:limit].to_i.clamp(1, 1000) : 500
          offset = params[:offset].to_i.clamp(0, rows.size)

          render json: {
            library_id: @library.id,
            count: rows.size,
            items: rows[offset, limit].to_a.map { |p| content_row(p.plan, placement: p, paths: paths) }
          }
        end

        # The audit log: who filed/moved/removed what, when, and whether a
        # human or an agent did it. Owner (and admin) only.
        def events
          unless writable? || current_user.admin?
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          events = @library.library_events.recent_first.includes(:actor_user)
          events = events.where(created_at: ...Time.iso8601(params[:before])) if params[:before].present?
          events = events.where(event_type: params[:event_type]) if params[:event_type].present?
          events = events.where(plan_id: params[:plan_id]) if params[:plan_id].present?
          events = events.where(run_id: params[:run_id]) if params[:run_id].present?
          limit = params[:limit].present? ? params[:limit].to_i.clamp(1, 200) : 50

          render json: events.limit(limit).map { |e| event_json(e) }
        rescue ArgumentError
          render json: { error: "before must be an ISO 8601 timestamp" }, status: :unprocessable_content
        end

        # Bulk write: an array of operations (see Libraries::Organize for
        # the vocabulary), each atomic, with dry_run for proposing a
        # reorganization before applying it.
        def organize
          result = Libraries::Organize.call(
            library: @library,
            actor: current_user,
            operations: params[:operations],
            actor_type: api_author_type,
            actor_label: @api_token&.name,
            dry_run: params[:dry_run].to_s == "true"
          )
          unless result.success?
            return render json: { error: result.error }, status: :unprocessable_content
          end

          render json: {
            dry_run: result.dry_run,
            applied: !result.dry_run,
            run_id: result.run_id,
            ok_count: result.results.count { |r| r[:status] == "ok" },
            error_count: result.results.count { |r| r[:status] == "error" },
            results: result.results
          }
        end

        private

        # Blank id (the bare /api/v1/library routes) means the caller's own.
        def set_library
          @library = if params[:id].present?
            Library.find_by(id: params[:id])
          else
            current_user.library
          end
          render json: { error: "Library not found" }, status: :not_found unless @library
        end

        def writable?
          @library.writable_by?(current_user)
        end

        def owner_json(library)
          owner = library.owner
          {
            type: library.owner_type.demodulize.underscore,
            id: library.owner_id,
            name: owner.respond_to?(:name) ? owner.name : nil
          }
        end

        def visible_placement_counts
          @library.placements
            .visible_to(current_user)
            .where(plan: Plan.active)
            .group(:folder_id)
            .count
        end

        # Own count + every descendant's, computed from the in-memory tree.
        def subtree_totals(folders, counts)
          children = folders.group_by(&:parent_id)
          totals = {}
          compute = lambda do |folder, seen|
            return 0 unless seen.add?(folder.id)
            totals[folder.id] ||= counts.fetch(folder.id, 0) +
              (children[folder.id] || []).sum { |child| compute.call(child, seen) }
          end
          folders.each { |f| compute.call(f, Set.new) }
          totals
        end

        # The library owner's active plans not yet shelved in this library —
        # only meaningful when the caller can write (i.e. it's their shelf).
        def unfiled_plans
          current_user.created_plans
            .active
            .where.not(id: @library.placements.select(:plan_id))
        end

        def top_tags_json
          placed_plan_ids = @library.placements.visible_to(current_user).select(:plan_id)
          Tag.joins(:plan_tags)
            .where(coplan_plan_tags: { plan_id: placed_plan_ids })
            .group("coplan_tags.id", "coplan_tags.name")
            .order(Arel.sql("COUNT(*) DESC"), "coplan_tags.name ASC")
            .limit(10)
            .count
            .map { |(_id, name), count| { name: name, plans_count: count } }
        end

        def content_row(plan, placement:, paths:)
          {
            plan_id: plan.id,
            title: plan.title,
            summary: plan.summary,
            tags: plan.tag_names,
            visibility: plan.visibility,
            archived: plan.archived?,
            author: plan.created_by_user&.name,
            folder_id: placement&.folder_id,
            folder_path: placement ? paths[placement.folder_id] : nil,
            placed_by: placement&.placed_by_user&.name,
            placed_at: placement&.updated_at,
            created_at: plan.created_at,
            updated_at: plan.updated_at
          }
        end

        def event_json(event)
          {
            id: event.id,
            event_type: event.event_type,
            actor_type: event.actor_type,
            agent: event.actor_type != "human",
            actor: event.actor_user && { id: event.actor_user.id, name: event.actor_user.name },
            actor_label: event.metadata["actor_label"],
            run_id: event.run_id,
            plan_id: event.plan_id,
            plan_title: event.metadata["plan_title"],
            folder_id: event.folder_id,
            before: event.before_value,
            after: event.after_value,
            created_at: event.created_at
          }
        end

        def find_folder_param
          if params[:folder_id].present?
            @library.folders.find_by(id: params[:folder_id])
          else
            Folder.find_by_path(params[:folder_path], library: @library)
          end
        end
      end
    end
  end
end
