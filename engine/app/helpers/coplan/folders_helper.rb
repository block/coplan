module CoPlan
  module FoldersHelper
    # [[path, id, depth], ...] for every folder in the viewer's library,
    # sorted by path — used by the "New folder" parent select and each
    # row's "Move to folder" menu. Memoized per request and seeded from
    # the controller-loaded tree (@folders) when available, so rendering
    # many rows doesn't re-query.
    def folder_select_options
      @_folder_select_options ||= folder_paths_by_id
        .map { |id, path| [ path, id, path.count("/") + 1 ] }
        .sort_by { |path, _id, _depth| path.downcase }
    end

    # Where the current user shelved this plan in their own library (nil
    # when unfiled). One placements query per request, not per row.
    def viewer_folder_id(plan)
      @_viewer_folder_ids ||= current_user.library.placements.pluck(:plan_id, :folder_id).to_h
      @_viewer_folder_ids[plan.id]
    end

    def folder_paths_by_id
      @_folder_paths_by_id ||= CoPlan::Folder.paths_by_id(@folders || current_user.library.folders.order(:name).to_a)
    end
  end
end
