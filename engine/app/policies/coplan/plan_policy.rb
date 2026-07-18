module CoPlan
  class PlanPolicy < ApplicationPolicy
    # Drafts are unlisted, not locked: anyone who has the URL may read the
    # plan (share a link to get early feedback). What "draft" withholds is
    # discovery — lists, feeds, search, counts, shelves — which is decided
    # by `listed?` / Plan.visible_to, never here.
    def show?
      true
    end

    # THE discovery predicate, mirroring the Plan.visible_to scope. Every
    # surface that *surfaces* a plan — lists, feeds, search, folder
    # contents, library placements, profile pages — must answer through
    # here (or the scope for set-based queries). Never test
    # `visibility`/`archived_at` inline in controllers or views.
    def listed?
      record.published? || record.created_by_user_id == user&.id
    end

    def update?
      record.created_by_user_id == user.id
    end

    # Adding references and attachments is collaboration, not authorship —
    # open to any signed-in user, like commenting. Removing them stays with
    # the plan's author (update?).
    def contribute?
      user.present?
    end

    # Publishing a draft is explicit and confirmed in the UI ("publishes to
    # everyone"). There is no unpublish — retracting an already-read document
    # is a lie; archiving is the tool for "I'm done with this".
    def publish?
      update? && record.draft?
    end

    def archive?
      update? && !record.archived?
    end

    def unarchive?
      update? && record.archived?
    end

    # Editing plan content in the web UI. Same rule as metadata for now:
    # the author owns the document. Agents edit via the API under their
    # own authorization path.
    def edit_content?
      update?
    end
  end
end
