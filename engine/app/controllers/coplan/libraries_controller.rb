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
      @plan_counts = Plan.visible_to(current_user).active
        .joins(:placement)
        .group("coplan_plan_placements.library_id").count
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

    def browse_url_for(library, folder)
      return browse_library_path(handle: library.handle) if folder.nil?

      browse_path(handle: library.handle, slug_path: folder.slug_path)
    end
  end
end
