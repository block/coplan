module CoPlan
  module FoldersHelper
    # [[path, id, depth], ...] for every folder, sorted by path — used by
    # the "New folder" parent select and each row's "Move to folder" menu.
    # Memoized per request; builds paths in memory so rendering many rows
    # doesn't re-query the tree.
    def folder_select_options
      @_folder_select_options ||= begin
        folders = CoPlan::Folder.order(:name).to_a
        by_id = folders.index_by(&:id)
        folders.map { |folder|
          names = folder_lineage_names(folder, by_id)
          [names.join("/"), folder.id, names.length]
        }.sort_by { |path, _id, _depth| path.downcase }
      end
    end

    # Full "Parent/Child" path for a folder, using the memoized tree when
    # it has been built (index page) and falling back to the association
    # walk otherwise.
    def folder_path_for(folder)
      return folder.path unless defined?(@_folder_select_options) && @_folder_select_options

      option = @_folder_select_options.find { |_path, id, _depth| id == folder.id }
      option ? option[0] : folder.path
    end

    private

    def folder_lineage_names(folder, by_id)
      names = [folder.name]
      node = folder
      while node.parent_id && (node = by_id[node.parent_id])
        names.unshift(node.name)
        break if names.length > CoPlan::Folder::MAX_DEPTH # cycle guard
      end
      names
    end
  end
end
