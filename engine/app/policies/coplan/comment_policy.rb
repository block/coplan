module CoPlan
  class CommentPolicy < ApplicationPolicy
    def update?
      delete? && !record.deleted?
    end

    def delete?
      record.author_type == "human" && record.author_id == user&.id
    end
  end
end
