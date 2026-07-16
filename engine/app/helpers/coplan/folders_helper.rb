module CoPlan
  module FoldersHelper
    # [[path, id, depth], ...] for every folder, sorted by path — used by
    # the "New folder" parent select and each row's "Move to folder" menu.
    # Memoized per request and seeded from the controller-loaded tree
    # (@folders) when available, so rendering many rows doesn't re-query.
    def folder_select_options
      @_folder_select_options ||= folder_paths_by_id
        .map { |id, path| [ path, id, path.count("/") + 1 ] }
        .sort_by { |path, _id, _depth| path.downcase }
    end

    # Full "Parent/Child" path for a folder without walking associations.
    def folder_path_for(folder)
      folder_paths_by_id[folder.id] || folder.path
    end

    private

    def folder_paths_by_id
      @_folder_paths_by_id ||= CoPlan::Folder.paths_by_id(@folders || CoPlan::Folder.order(:name).to_a)
    end
  end
end
