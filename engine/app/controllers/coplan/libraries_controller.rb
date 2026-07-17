module CoPlan
  # Read-only library browsing — the addressable page behind folder-jump
  # discovery ("this plan was useful; what does its author keep next to
  # it?"). Anyone signed in can look; what they see inside is filtered
  # per-plan by Plan.visible_to, and archived plans stay hidden here like
  # everywhere else. Editing a library happens in its owner's workspace,
  # never on this page.
  class LibrariesController < ApplicationController
    def mine
      redirect_to library_path(current_user.library)
    end

    def show
      @library = Library.find(params[:id])
      authorize!(@library, :show?)

      @owner = @library.owner
      @folders = @library.folders.order(:name).to_a
      @folder_children = @folders.group_by(&:parent_id)
      @root_folders = @folder_children[nil] || []

      placements = @library.placements
        .visible_to(current_user)
        .where(plan: Plan.active)
        .includes(plan: [ :created_by_user, :plan_type, :tags ])
        .sort_by { |p| p.plan.updated_at }
        .reverse
      @placements_by_folder = placements.group_by(&:folder_id)
      @plan_count = placements.size
    end
  end
end
