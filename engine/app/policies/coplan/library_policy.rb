module CoPlan
  # Libraries are browsable by anyone signed in — what a viewer actually
  # sees inside one is decided per-plan by Plan.visible_to, never here.
  # Writing (creating folders, shelving plans) is the library's call.
  class LibraryPolicy < ApplicationPolicy
    def show?
      true
    end

    def update?
      record.writable_by?(user)
    end
  end
end
