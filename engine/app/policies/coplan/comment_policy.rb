module CoPlan
  class CommentPolicy < ApplicationPolicy
    def update?
      record.author_type == "human" && delete? && !record.deleted?
    end

    def delete?
      user.present? && record.author_type.in?(%w[human local_agent]) && record.author_id == user.id
    end
  end
end
