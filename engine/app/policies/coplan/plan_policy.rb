module CoPlan
  class PlanPolicy < ApplicationPolicy
    # THE visibility predicate. Every surface that shows a plan — lists,
    # feeds, search, folder contents, library placements, profile pages —
    # must answer through here (or the mirrored Plan.visible_to scope for
    # set-based queries). Never test `visibility`/`archived_at` inline in
    # controllers or views.
    def show?
      record.published? || record.created_by_user_id == user&.id
    end

    def update?
      record.created_by_user_id == user.id
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
