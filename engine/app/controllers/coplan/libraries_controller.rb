module CoPlan
  # A library is a data-model concept, not a destination: a person's
  # library is browsed on their profile, so these routes redirect there
  # (fragments like #folder-x survive the redirect). The standalone page
  # only renders for a future non-user owner (e.g. a team) that has no
  # profile to redirect to.
  class LibrariesController < ApplicationController
    def mine
      redirect_to profile_path(current_user.username.presence || current_user.id)
    end

    def show
      @library = Library.find(params[:id])
      authorize!(@library, :show?)

      if @library.owner.is_a?(CoPlan::User)
        owner = @library.owner
        redirect_to profile_path(owner.username.presence || owner.id)
        return
      end

      @owner = @library.owner
      @folders = @library.folders.order(:name).to_a
      @folder_children = @folders.group_by(&:parent_id)
      @root_folders = @folder_children[nil] || []

      placements = @library.placements
        .visible_to(current_user)
        .where(plan: Plan.active)
        .joins(:plan).order("coplan_plans.updated_at DESC")
        .includes(plan: [ :created_by_user, :plan_type, :tags ])
        .to_a
      @placements_by_folder = placements.group_by(&:folder_id)
      @plan_count = placements.size
    end
  end
end
