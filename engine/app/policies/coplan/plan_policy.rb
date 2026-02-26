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
  end
end
