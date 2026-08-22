module CoPlan
  # The id-based entry points into library browsing, kept so old links keep
  # working, plus the index of every library you can see.
  #
  # The canonical URLs are the browsable paths (/:handle/...) served by
  # BrowseController; #show sends id-based links there with a 301 so the
  # address bar — and anything copied out of it — says the readable form.
  class LibrariesController < ApplicationController
    def mine
      redirect_to browse_library_path(handle: current_user.library.handle)
    end

    # Every library you can see, at /_/libraries. Not a place inside anyone's
    # library — it's the list of them — so it lives under `_` rather than
    # taking a top-level segment away from someone's handle.
    def index
      # Your own library first, so the list can't omit it. Libraries are
      # materialized on first touch (User#library), and reading the table
      # directly is exactly the path that skips that — a user who'd never
      # loaded a page that links their library got a list without it.
      current_user.library

      @libraries = Library.includes(:owner).order(:handle).to_a
      @plan_counts = plan_counts_for(@libraries)
    end

    def show
      library = Library.find(params[:id])
      authorize!(library, :show?)

      folder = params[:folder].present? ? library.folders.find_by(id: params[:folder]) : nil
      if params[:folder].present? && folder.nil?
        redirect_to browse_library_path(handle: library.handle), alert: "That folder no longer exists."
        return
      end

      redirect_to browse_url_for(library, folder), status: :moved_permanently
    end

    private

    # What clicking the row will show you, which is both senses of "in this
    # library": filed into one of its folders, and loose at its root. A
    # plan at a library root has no placement row by design, so counting
    # placements alone called a library of nothing but unfiled work
    # "empty" — see Library#unfiled_plans.
    def plan_counts_for(libraries)
      visible = Plan.visible_to(current_user).active
      counts = visible.joins(:placement).group("coplan_plan_placements.library_id").count
      unfiled = visible.where.not(id: PlanPlacement.select(:plan_id)).group(:created_by_user_id).count

      libraries.each_with_object(counts) do |library, totals|
        next unless library.owner_type == "CoPlan::User"

        loose = unfiled[library.owner_id].to_i
        totals[library.id] = totals[library.id].to_i + loose if loose.positive?
      end
    end

    def browse_url_for(library, folder)
      return browse_library_path(handle: library.handle) if folder.nil?

      browse_path(handle: library.handle, slug_path: folder.slug_path)
    end
  end
end
