module CoPlan
  class PlanCollaborator < ApplicationRecord
    ROLES = %w[author reviewer viewer approver highlighted].freeze

    belongs_to :plan
    belongs_to :user, class_name: "CoPlan::User"
    belongs_to :added_by_user, class_name: "CoPlan::User", optional: true

    validates :role, presence: true, inclusion: { in: ROLES }
    validates :user_id, uniqueness: { scope: :plan_id }
    validates :highlighted_reason, presence: true, if: -> { role == "highlighted" }

    before_validation :clear_irrelevant_role_data

    private

    def clear_irrelevant_role_data
      self.approved_at = nil unless role == "approver"
      self.highlighted_reason = nil unless role == "highlighted"
    end

    public

    scope :authors, -> { where(role: "author") }
    scope :reviewers, -> { where(role: "reviewer") }
    scope :approvers, -> { where(role: "approver") }
    scope :highlighted, -> { where(role: "highlighted") }

    def approve!
      update!(approved_at: Time.current)
    end

    def approved?
      approved_at.present?
    end
  end
end
