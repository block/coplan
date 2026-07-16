module CoPlan
  # Folders are shared/org-wide: any signed-in user can see them and create
  # new ones. Rename/re-parent/delete is limited to the folder's creator or
  # an admin so shared structure doesn't get reshuffled by accident.
  class FolderPolicy < ApplicationPolicy
    def index?
      true
    end

    def create?
      true
    end

    def update?
      record.created_by_user_id == user.id || admin?
    end

    def destroy?
      update?
    end
  end
end
