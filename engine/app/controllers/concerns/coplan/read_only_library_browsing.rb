module CoPlan
  # Loads the level-by-level view of a library the viewer can't write to:
  # the same folder model as the owner's workspace, without drag, move, or
  # create controls.
  #
  # Extracted so both entry points share it — LibrariesController#show
  # (the legacy /libraries/:id form) and BrowseController (the canonical
  # /l/:handle/... paths).
  module ReadOnlyLibraryBrowsing
    extend ActiveSupport::Concern

    private

    # Sets every ivar `coplan/libraries/show` renders. `folder` is the
    # already-resolved folder to display, or nil for the library root.
    def load_read_only_library(library, folder)
      @library = library
      @owner = library.owner
      @folder = folder
      @folders = library.folders.order(:name).to_a
      @folders_by_id = @folders.index_by(&:id)
      @folder_children = @folders.group_by(&:parent_id)

      placements = library.placements
        .visible_to(current_user)
        .where(plan: Plan.active)
        .joins(:plan).order("coplan_plans.updated_at DESC")
        .includes(:folder, plan: [ :created_by_user, :plan_type, :current_version_stub ])
        .to_a
      @placements_by_folder = placements.group_by(&:folder_id)
      @root_plans = unfiled_plans_for(library)

      @breadcrumbs = []
      node = @folder
      while node
        @breadcrumbs.unshift(node)
        node = @folders_by_id[node.parent_id]
      end
      @subfolders = (@folder_children[@folder&.id] || []).sort_by { |folder| folder.name.downcase }
      @plans = @folder ? (@placements_by_folder[@folder.id] || []).map(&:plan) : @root_plans
      @plan_count = placements.size + @root_plans.size
      @folder_counts = subtree_counts(@folders, @placements_by_folder, @folder_children)
    end

    def unfiled_plans_for(library)
      library.unfiled_plans
        .merge(Plan.visible_to(current_user))
        .active
        .order(updated_at: :desc)
        .includes(:created_by_user, :plan_type, :current_version_stub)
        .to_a
    end

    # Counts are "what clicking this shows" — a folder's own plans plus
    # everything nested beneath it.
    def subtree_counts(folders, placements_by_folder, folder_children)
      direct = placements_by_folder.transform_values(&:size)
      count = lambda do |folder|
        direct.fetch(folder.id, 0) + (folder_children[folder.id] || []).sum { |child| count.call(child) }
      end
      folders.index_with { |folder| count.call(folder) }.transform_keys(&:id)
    end
  end
end
