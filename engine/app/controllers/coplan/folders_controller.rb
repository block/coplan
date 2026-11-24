module Coplan
  # Web-side folder management for the plans sidebar: creation ("New
  # folder" input), reparenting (dragging one folder onto another), and
  # deleting an empty folder. Folders always land in the current user's
  # own library — there's no picking someone else's. Rename happens
  # through the API or admin UI for now.
  class FoldersController < ApplicationController
    # JSON-only: this sits behind the drag-and-drop in the folder tree.
    # The Folder model owns the interesting rules — cycles, cross-library
    # parents, and the depth cap all come back as validation errors.
    def update
      library = current_user.library
      folder = library.folders.find_by(id: params[:id])
      return render json: { error: I18n.t("coplan.common.messages.unknown_folder") }, status: :not_found unless folder

      parent = nil
      if params[:parent_id].present?
        parent = library.folders.find_by(id: params[:parent_id])
        return render json: { error: I18n.t("coplan.library.messages.unknown_destination_folder") }, status: :unprocessable_content unless parent
      end

      old_path = folder.path
      folder.parent = parent
      if folder.save
        if folder.saved_change_to_parent_id?
          Libraries::LogEvent.call(
            library: library, actor: current_user,
            event_type: "folder_moved", folder: folder,
            before: old_path, after: folder.path
          )
        end
        render json: {
          parent_id: folder.parent_id,
          path: folder.path,
          message: I18n.t("coplan.common.messages.moved_name_to_level", name: folder.name, level: parent ? parent.path : "the top level")
        }
      else
        render json: { error: I18n.t("coplan.library.messages.couldn_t_move_folder_errors", errors: folder.errors.full_messages.join(", ")) },
          status: :unprocessable_content
      end
    end

    # Only empty folders go: Folder#ensure_empty refuses the rest.
    def destroy
      folder = Folder.find_by(id: params[:id])
      unless folder && FolderPolicy.new(current_user, folder).destroy?
        redirect_to helpers.own_library_browse_path(current_user), alert: I18n.t("coplan.common.messages.that_folder_no_longer_exists")
        return
      end

      path = folder.path
      parent = folder.parent
      if folder.destroy
        Libraries::LogEvent.call(
          library: folder.library, actor: current_user,
          event_type: "folder_deleted", before: path,
          metadata: { folder_name: folder.name }
        )
        redirect_to parent ? helpers.folder_browse_path(parent) : helpers.library_browse_path(folder.library),
          notice: I18n.t("coplan.library.messages.folder_name_deleted", name: folder.name)
      else
        redirect_to helpers.folder_browse_path(folder),
          alert: I18n.t("coplan.library.messages.couldn_t_delete_folder_errors", errors: folder.errors.full_messages.join(", "))
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
          redirect_back fallback_location: helpers.own_library_browse_path(current_user),
            alert: I18n.t("coplan.library.messages.couldn_t_create_folder_the")
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
        Libraries::LogEvent.call(
          library: library, actor: current_user,
          event_type: "folder_created", folder: folder, after: folder.path
        )
        # Straight to the new folder's own address — it's a place now, so
        # that's where "created" lands.
        redirect_to helpers.folder_browse_path(folder), notice: I18n.t("coplan.library.messages.folder_name_created", name: folder.name)
      else
        redirect_back fallback_location: helpers.own_library_browse_path(current_user),
          alert: I18n.t("coplan.library.messages.couldn_t_create_folder_errors", errors: folder.errors.full_messages.join(", "))
      end
    end
  end
end
