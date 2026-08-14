module CoPlan
  module Api
    module V1
      class FoldersController < BaseController
        before_action :set_folder, only: [ :update, :destroy ]

        # Defaults to the caller's own library; pass library_id to browse
        # another library's tree read-only (counts stay viewer-filtered).
        def index
          library = if params[:library_id].present?
            Library.find_by(id: params[:library_id])
          else
            current_user.library
          end
          return render json: { error: "Library not found" }, status: :not_found unless library

          folders = library.folders.order(:name).to_a
          paths = Folder.paths_by_id(folders)

          # Visible-plan counts only — never leak the existence of other
          # users' unlisted drafts through folder counts. Archived plans
          # are excluded too, matching the web sidebar and library page.
          counts = PlanPlacement.where(library_id: library.id)
            .visible_to(current_user)
            .where(plan: Plan.active)
            .group(:folder_id)
            .count

          render json: folders.map { |f| folder_json(f, paths: paths, counts: counts) }
        end

        # Always creates in the caller's own library — you can't write to
        # someone else's shelf.
        def create
          library = current_user.library

          parent = nil
          if params[:parent_id].present?
            parent = library.folders.find_by(id: params[:parent_id])
            return render json: { error: "Unknown parent_id" }, status: :unprocessable_content unless parent
          end

          folder = Folder.create!(
            name: params[:name],
            description: params[:description],
            parent: parent,
            library: library,
            created_by_user: current_user
          )
          Libraries::LogEvent.call(
            library: library, actor: current_user, actor_type: api_author_type,
            event_type: "folder_created", folder: folder, after: folder.path
          )
          render json: folder_json(folder), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
        end

        def update
          policy = FolderPolicy.new(current_user, @folder)
          unless policy.update?
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          attrs = {}
          attrs[:name] = params[:name] if params.key?(:name)
          attrs[:description] = params[:description] if params.key?(:description)
          if params.key?(:parent_id)
            if params[:parent_id].present?
              parent = @folder.library.folders.find_by(id: params[:parent_id])
              return render json: { error: "Unknown parent_id" }, status: :unprocessable_content unless parent
              attrs[:parent] = parent
            else
              attrs[:parent] = nil
            end
          end

          old_path = @folder.path
          old_description = @folder.description
          @folder.update!(attrs)
          log_folder_update(old_path, old_description)
          render json: folder_json(@folder)
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
        end

        def destroy
          policy = FolderPolicy.new(current_user, @folder)
          unless policy.destroy?
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          path = @folder.path
          if @folder.destroy
            Libraries::LogEvent.call(
              library: @folder.library, actor: current_user, actor_type: api_author_type,
              event_type: "folder_deleted", before: path,
              metadata: { folder_name: @folder.name }
            )
            head :no_content
          else
            render json: { error: @folder.errors.full_messages.join(", ") }, status: :unprocessable_content
          end
        end

        private

        def set_folder
          @folder = Folder.find_by(id: params[:id])
          render json: { error: "Folder not found" }, status: :not_found unless @folder
        end

        # One update call can rename, move, and re-describe at once — log
        # each change as its own audit event so the library log stays
        # readable ("renamed A → B", not "something about this folder").
        def log_folder_update(old_path, old_description)
          new_path = @folder.path
          if @folder.saved_change_to_name?
            Libraries::LogEvent.call(
              library: @folder.library, actor: current_user, actor_type: api_author_type,
              event_type: "folder_renamed", folder: @folder, before: old_path, after: new_path
            )
          end
          if @folder.saved_change_to_parent_id?
            Libraries::LogEvent.call(
              library: @folder.library, actor: current_user, actor_type: api_author_type,
              event_type: "folder_moved", folder: @folder, before: old_path, after: new_path
            )
          end
          if @folder.saved_change_to_description?
            Libraries::LogEvent.call(
              library: @folder.library, actor: current_user, actor_type: api_author_type,
              event_type: "folder_described", folder: @folder,
              before: old_description, after: @folder.description,
              metadata: { path: new_path }
            )
          end
        end

        # `paths` and `counts` let index serialize the whole tree without
        # per-folder queries. `plans_count` is the folder's own visible
        # placements (not including subfolders).
        def folder_json(folder, paths: nil, counts: nil)
          {
            id: folder.id,
            name: folder.name,
            description: folder.description,
            library_id: folder.library_id,
            parent_id: folder.parent_id,
            path: paths ? paths[folder.id] : folder.path,
            plans_count: counts ? counts.fetch(folder.id, 0) : folder.placements.visible_to(current_user).where(plan: Plan.active).count,
            created_by: folder.created_by_user&.name,
            created_at: folder.created_at,
            updated_at: folder.updated_at
          }
        end
      end
    end
  end
end
