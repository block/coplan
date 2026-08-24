module CoPlan
  # A placement files a plan in a library folder. A plan has at most one:
  # it lives in exactly one place, the way a file does. Filing it
  # somewhere else is a move, never a second copy — which is what lets a
  # document have a single readable address (see Plan#url_path).
  #
  # Placements carry their own metadata (who placed it, when) — they're a
  # first-class attachment, not a bare join row. Visibility is inherited
  # from the plan: a placement is visible iff the underlying plan is
  # visible to the viewer (see .visible_to), whoever's library it sits in.
  class PlanPlacement < ApplicationRecord
    include BroadcastsLibraryChanges

    belongs_to :plan, class_name: "CoPlan::Plan", inverse_of: :placement
    belongs_to :folder, class_name: "CoPlan::Folder", inverse_of: :placements
    belongs_to :library, class_name: "CoPlan::Library", inverse_of: :placements
    belongs_to :placed_by_user, class_name: "CoPlan::User", optional: true

    before_validation :inherit_library_from_folder

    # One spot, period: re-filing a plan moves it, in or across libraries.
    validates :plan_id, uniqueness: { message: "is already filed somewhere — move it instead" }
    validate :folder_must_belong_to_library

    # THE visibility rule for placements: defer entirely to the plan's
    # predicate. Every surface that lists placements (library browsing,
    # folder-jump, workspace) goes through this scope.
    scope :visible_to, ->(user) { where(plan: Plan.visible_to(user)) }

    # Filing, moving and unfiling all change two listings at once: the
    # document leaves one place and arrives in another. A cross-library
    # move is the case that needs both libraries told, so this reads the
    # previous library_id rather than assuming it didn't change.
    after_commit :broadcast_placement_change

    private

    def broadcast_placement_change
      previous_id = library_id_previously_was
      previous = previous_id.presence && previous_id != library_id ? Library.find_by(id: previous_id) : nil
      broadcast_library_refresh(library, previous)

      # The document's own page shows where it lives — the up-arrow beside
      # the title — so a move has to land there too. Re-read the plan first:
      # this row may be the one that just went away, and `plan.placement`
      # would still hand it back.
      fresh = Plan.find_by(id: plan_id)
      return if fresh.nil?

      Broadcaster.replace_to(fresh, target: "plan-nav-context",
        partial: "coplan/plans/nav_context", locals: { plan: fresh })
    end

    # library_id is denormalized from the folder so library-scoped reads
    # ("everything filed in this library") don't need the folder join;
    # callers only ever pick a folder.
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
