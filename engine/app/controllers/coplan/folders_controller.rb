module CoPlan
  # Web-side folder creation for the plans sidebar ("New folder" form).
  # Folders always land in the current user's own library — there's no
  # picking someone else's. Rename/delete happen through the API or admin
  # UI for now.
  class FoldersController < ApplicationController
    def create
      library = current_user.library

      parent = nil
      if params.dig(:folder, :parent_id).present?
        parent = library.folders.find_by(id: params.dig(:folder, :parent_id))
        if parent.nil?
          # Don't silently create a root folder when the chosen parent has
          # since been deleted (matches the API's unknown-parent handling).
          redirect_back fallback_location: plans_path,
            alert: "Couldn't create folder: the parent folder no longer exists."
          return
        end
      end

      folder = Folder.new(
        name: params.dig(:folder, :name),
        parent: parent,
        library: library,
        created_by_user: current_user
      )

      if folder.save
        redirect_to plans_path(folder: folder.id), notice: "Folder “#{folder.name}” created."
      else
        redirect_back fallback_location: plans_path,
          alert: "Couldn't create folder: #{folder.errors.full_messages.join(", ")}"
      end
    end
  end
end
