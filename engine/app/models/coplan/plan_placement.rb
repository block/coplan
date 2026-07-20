module CoPlan
  # A placement shelves a plan in a library folder. It is the library
  # owner's organization of the plan, not a property of the plan itself:
  # the same plan can sit in many libraries at once, and shelving someone
  # else's published plan is a first-class action — a placement, never a
  # copy or a move.
  #
  # Placements carry their own metadata (who placed it, when) — they're a
  # first-class attachment, not a bare join row. Visibility is inherited
  # from the plan: a placement is visible iff the underlying plan is
  # visible to the viewer (see .visible_to), whoever's library it sits in.
  class PlanPlacement < ApplicationRecord
    belongs_to :plan, class_name: "CoPlan::Plan", inverse_of: :placements
    belongs_to :folder, class_name: "CoPlan::Folder", inverse_of: :placements
    belongs_to :library, class_name: "CoPlan::Library", inverse_of: :placements
    belongs_to :placed_by_user, class_name: "CoPlan::User", optional: true

    before_validation :inherit_library_from_folder

    # One spot per library: a plan sits in exactly one folder of a given
    # library (re-shelving moves it, it doesn't duplicate it).
    validates :plan_id, uniqueness: { scope: :library_id }
    validate :folder_must_belong_to_library

    # THE visibility rule for placements: defer entirely to the plan's
    # predicate. Every surface that lists placements (library browsing,
    # folder-jump, workspace) goes through this scope.
    scope :visible_to, ->(user) { where(plan: Plan.visible_to(user)) }

    private

    # library_id is denormalized from the folder so "one spot per library"
    # is enforceable with a unique index; callers only pick a folder.
    def inherit_library_from_folder
      self.library_id ||= folder&.library_id
    end

    def folder_must_belong_to_library
      return if folder.nil? || library_id.nil?
      return if folder.library_id == library_id

      errors.add(:folder, "must belong to the placement's library")
    end
  end
end
