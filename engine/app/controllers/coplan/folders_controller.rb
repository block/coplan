module CoPlan
  # Web-side folder creation for the plans sidebar ("New folder" form).
  # Folder rename/delete happen through the API or admin UI for now.
  class FoldersController < ApplicationController
    def create
      parent = nil
      if params.dig(:folder, :parent_id).present?
        parent = Folder.find_by(id: params.dig(:folder, :parent_id))
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
