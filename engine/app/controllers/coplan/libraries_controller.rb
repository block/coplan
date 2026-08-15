module CoPlan
  # Read-only folder navigation for someone else's library. Owners continue
  # into their editable workspace; everyone else gets the same level-by-level
  # folder model without drag, move, or create controls.
  class LibrariesController < ApplicationController
    def mine
      redirect_to plans_path
    end

    def show
      @library = Library.find(params[:id])
      authorize!(@library, :show?)

      if @library.writable_by?(current_user)
        redirect_to plans_path(folder: params[:folder].presence)
        return
      end

      @owner = @library.owner
      @folders = @library.folders.order(:name).to_a
      @folders_by_id = @folders.index_by(&:id)
      @folder_children = @folders.group_by(&:parent_id)
      @folder = @folders_by_id[params[:folder]] if params[:folder].present?
      if params[:folder].present? && @folder.nil?
        redirect_to library_path(@library), alert: "That folder no longer exists."
        return
      end

      placements = @library.placements
        .visible_to(current_user)
        .where(plan: Plan.active)
        .joins(:plan).order("coplan_plans.updated_at DESC")
        .includes(:folder, plan: [ :created_by_user, :plan_type, :current_version_stub ])
        .to_a
      @placements_by_folder = placements.group_by(&:folder_id)

      @root_plans = if @owner.is_a?(CoPlan::User)
        Plan.visible_to(current_user).active
          .where(created_by_user_id: @owner.id)
          .where.not(id: @library.placements.select(:plan_id))
          .order(updated_at: :desc)
          .includes(:created_by_user, :plan_type, :current_version_stub)
          .to_a
      else
        []
      end

      @breadcrumbs = []
      node = @folder
      while node
        @breadcrumbs.unshift(node)
        node = @folders_by_id[node.parent_id]
      end
      @subfolders = (@folder_children[@folder&.id] || []).sort_by { |folder| folder.name.downcase }
      @plans = @folder ? (@placements_by_folder[@folder.id] || []).map(&:plan) : @root_plans
      @plan_count = placements.size + @root_plans.size

      direct_counts = @placements_by_folder.transform_values(&:size)
      count_folder = lambda do |folder|
        direct_counts.fetch(folder.id, 0) + (@folder_children[folder.id] || []).sum { |child| count_folder.call(child) }
      end
      @folder_counts = @folders.index_with { |folder| count_folder.call(folder) }.transform_keys(&:id)
    end
  end
end
