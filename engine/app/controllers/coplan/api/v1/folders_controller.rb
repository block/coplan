module CoPlan
  module Api
    module V1
      class FoldersController < BaseController
        before_action :set_folder, only: [ :update, :destroy ]

        def index
          folders = Folder.order(:name).to_a
          paths = Folder.paths_by_id(folders)

          # Visible-plan counts only — never leak the existence of other
          # users' private draft plans through folder counts.
          counts = Plan.visible_to(current_user)
            .where.not(folder_id: nil)
            .group(:folder_id)
            .count

          render json: folders.map { |f| folder_json(f, paths: paths, counts: counts) }
        end

        def create
          parent = nil
          if params[:parent_id].present?
            parent = Folder.find_by(id: params[:parent_id])
            return render json: { error: "Unknown parent_id" }, status: :unprocessable_content unless parent
          end

          folder = Folder.create!(
            name: params[:name],
            parent: parent,
            created_by_user: current_user
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
          if params.key?(:parent_id)
            if params[:parent_id].present?
              parent = Folder.find_by(id: params[:parent_id])
              return render json: { error: "Unknown parent_id" }, status: :unprocessable_content unless parent
              attrs[:parent] = parent
            else
              attrs[:parent] = nil
            end
          end

          @folder.update!(attrs)
          render json: folder_json(@folder)
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
        end

        def destroy
          policy = FolderPolicy.new(current_user, @folder)
          unless policy.destroy?
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          if @folder.destroy
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

        # `paths` and `counts` let index serialize the whole tree without
        # per-folder queries. `plans_count` is the folder's own visible
        # plans (not including subfolders).
        def folder_json(folder, paths: nil, counts: nil)
          {
            id: folder.id,
            name: folder.name,
            parent_id: folder.parent_id,
            path: paths ? paths[folder.id] : folder.path,
            plans_count: counts ? counts.fetch(folder.id, 0) : folder.plans.visible_to(current_user).count,
            created_by: folder.created_by_user&.name,
            created_at: folder.created_at,
            updated_at: folder.updated_at
          }
        end
      end
    end
  end
end
