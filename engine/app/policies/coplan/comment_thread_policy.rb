module CoPlan
  class CommentThreadPolicy < ApplicationPolicy
    def create?
      true
    end

    def resolve?
      record.created_by_user_id == user.id || record.plan.created_by_user_id == user.id
    end

    def accept?
      record.plan.created_by_user_id == user.id
    end

    def dismiss?
      record.plan.created_by_user_id == user.id
    end

    def reopen?
      record.created_by_user_id == user.id || record.plan.created_by_user_id == user.id
    end
  end
end
