module CoPlan
  # A task, independent of both inbox read state and collaborator permissions.
  class ReviewRequest < ApplicationRecord
    REQUIREMENTS = %w[required optional].freeze
    STATUSES = %w[pending approved changes_requested withdrawn removed].freeze

    belongs_to :plan
    belongs_to :reviewer, class_name: "CoPlan::User"
    belongs_to :requested_by_user, class_name: "CoPlan::User"
    # Historical context of when the request was sent, never a review target.
    # Pending requests follow the plan; only responses bind to a version.
    belongs_to :requested_plan_version, class_name: "CoPlan::PlanVersion"
    has_many :review_responses, -> { order(created_at: :desc, id: :desc) }, dependent: :delete_all
    has_many :notifications, dependent: :destroy

    # A nullable unique slot allows many ended assignments for one reviewer.
    # Keep it derived from status; false would create a second reusable slot.
    before_validation { self.current_assignment = status == "removed" ? nil : true }
    validates :reviewer_id, uniqueness: { scope: :plan_id, conditions: -> { current } }, unless: :removed?
    validates :current_assignment, inclusion: { in: [ true, nil ] }
    validates :requirement, inclusion: { in: REQUIREMENTS }
    validates :status, inclusion: { in: STATUSES }
    validates :requested_at, presence: true
    validate :version_belongs_to_plan

    scope :current, -> { where(current_assignment: true) }
    scope :active, -> { current.where.not(status: "withdrawn") }
    scope :pending, -> { current.where(status: "pending") }

    def removed?
      status == "removed"
    end

    def ensure_current!
      raise ActiveRecord::RecordNotFound, "Review request was removed" if removed?
    end

    def pending?
      status == "pending"
    end

    def latest_approval
      review_responses.find { |response| response.decision == "approved" }
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id plan_id reviewer_id requirement status requested_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[plan reviewer requested_by_user review_responses]
    end

    private

    def version_belongs_to_plan
      errors.add(:requested_plan_version, "must belong to this plan") if requested_plan_version && requested_plan_version.plan_id != plan_id
    end
  end
end
