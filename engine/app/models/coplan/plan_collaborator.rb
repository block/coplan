module CoPlan
  class PlanCollaborator < ApplicationRecord
    ROLES = %w[author reviewer viewer].freeze

    belongs_to :plan
    belongs_to :user, class_name: "CoPlan::User"
    belongs_to :added_by_user, class_name: "CoPlan::User", optional: true

    validates :role, presence: true, inclusion: { in: ROLES }
    validates :user_id, uniqueness: { scope: :plan_id }
  end
end
