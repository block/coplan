module CoPlan
  # Web-side folder management for the plans sidebar: creation ("New
  # folder" input) and reparenting (dragging one folder onto another).
  # Folders always land in the current user's own library — there's no
  # picking someone else's. Rename/delete happen through the API or admin
  # UI for now.
  class FoldersController < ApplicationController
    # JSON-only: this sits behind the drag-and-drop in the folder tree.
    # The Folder model owns the interesting rules — cycles, cross-library
    # parents, and the depth cap all come back as validation errors.
    def update
      library = current_user.library
      folder = library.folders.find_by(id: params[:id])
      return render json: { error: "Unknown folder" }, status: :not_found unless folder

      parent = nil
      if params[:parent_id].present?
        parent = library.folders.find_by(id: params[:parent_id])
        return render json: { error: "Unknown destination folder" }, status: :unprocessable_content unless parent
      end

      folder.parent = parent
      if folder.save
        render json: {
          parent_id: folder.parent_id,
          path: folder.path,
          message: "Moved “#{folder.name}” to #{parent ? parent.path : "the top level"}."
        }
      else
        render json: { error: "Couldn't move folder: #{folder.errors.full_messages.join(", ")}" },
          status: :unprocessable_content
      end
    end

    def create
      library = current_user.library
      # expect (Rails 8) turns a malformed payload into a 400, not a 500.
      folder_params = params.expect(folder: [ :name, :parent_id ])

      parent = nil
      if folder_params[:parent_id].present?
        parent = library.folders.find_by(id: folder_params[:parent_id])
        if parent.nil?
          # Don't silently create a root folder when the chosen parent has
          # since been deleted (matches the API's unknown-parent handling).
          redirect_back fallback_location: plans_path,
            alert: "Couldn't create folder: the parent folder no longer exists."
          return
        end
      end

      folder = Folder.new(
        name: folder_params[:name],
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
