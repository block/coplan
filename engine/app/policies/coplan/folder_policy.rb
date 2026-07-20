module CoPlan
  # Folders live inside a library, so every write defers to the library's
  # own policy (Library#writable_by?) — only the owner reshapes a personal
  # library's tree, with an admin override for cleanup. Reading is open:
  # anyone may browse a library's folder structure; the plans inside are
  # filtered per-viewer by Plan.visible_to.
  class FolderPolicy < ApplicationPolicy
    def index?
      true
    end

    def create?
      record.library&.writable_by?(user) || false
    end

    def update?
      create? || admin?
    end

    def destroy?
      update?
    end
  end
end
