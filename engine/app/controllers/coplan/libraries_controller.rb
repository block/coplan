module CoPlan
  # The id-based entry points into library browsing, kept so old links keep
  # working, plus the index at the top of the tree.
  #
  # The canonical URLs are the browsable paths (/l/:handle/...) served by
  # BrowseController; #show sends id-based links there with a 301 so the
  # address bar — and anything copied out of it — says the readable form.
  class LibrariesController < ApplicationController
    include ReadOnlyLibraryBrowsing

    def mine
      redirect_to browse_library_path(handle: current_user.library.handle)
    end

    # The top of the tree. `/l` is a real page because every prefix of a
    # browsable URL is one.
    def index
      @libraries = Library.includes(:owner).order(:handle).to_a
      @plan_counts = Plan.visible_to(current_user).active
        .joins(:placements)
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
