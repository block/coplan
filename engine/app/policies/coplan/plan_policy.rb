module CoPlan
  class PlanPolicy < ApplicationPolicy
    def show?
      if record.status == "brainstorm"
        record.created_by_user_id == user.id || record.plan_collaborators.exists?(user_id: user.id)
      else
        true
      end
    end

    def update?
      record.created_by_user_id == user.id
    end

    def update_status?
      update?
    end
  end
end
