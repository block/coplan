module CoPlan
  class PlanPolicy < ApplicationPolicy
    def show?
      true
    end

    def update?
      record.created_by_user_id == user.id
    end

    def update_status?
      update?
    end

    # Editing plan content in the web UI. Same rule as metadata for now:
    # the author owns the document. Agents edit via the API under their
    # own authorization path.
    def edit_content?
      update?
    end
  end
end
