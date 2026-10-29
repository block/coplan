module CoPlan
  # A task, independent of both inbox read state and collaborator permissions.
  class ReviewRequest < ApplicationRecord
    REQUIREMENTS = %w[required optional].freeze
    STATUSES = %w[pending approved changes_requested withdrawn].freeze

    belongs_to :plan
    belongs_to :reviewer, class_name: "CoPlan::User"
    belongs_to :requested_by_user, class_name: "CoPlan::User"
    # Historical context of when the request was sent, never a review target.
    # Pending requests follow the plan; only responses bind to a version.
    belongs_to :requested_plan_version, class_name: "CoPlan::PlanVersion"
    has_many :review_responses, -> { order(Arel.sql("CASE WHEN decision_sequence IS NULL THEN 0 ELSE 1 END DESC"), decision_sequence: :desc, created_at: :desc, id: :desc) }, dependent: :delete_all
    belongs_to :current_response, class_name: "CoPlan::ReviewResponse", optional: true
    has_many :notifications, dependent: :destroy

    validates :reviewer_id, uniqueness: { scope: :plan_id }
    validates :requirement, inclusion: { in: REQUIREMENTS }
    validates :status, inclusion: { in: STATUSES }
    validates :requested_at, presence: true
    validate :version_belongs_to_plan

    scope :active, -> { where.not(status: "withdrawn") }
    scope :pending, -> { where(status: "pending") }

    def pending?
      review_status == "pending"
    end

    # Positive history is for comparison only. Never use it as current evidence.
    def latest_approval
      review_responses.find { |response| response.decision == "approved" }
    end

    # Lifecycle completion may survive edits when automatic resets are off.
    # The recorded decision still covers only its original immutable version.
    def recorded_response
      response = current_response
      response if response && status == response.decision &&
        response.review_request_id == id && response.request_generation == generation
    end

    def review_status
      status == "withdrawn" ? "withdrawn" : (recorded_response&.decision || "pending")
    end

    # Exact-version evidence stays strict regardless of the reset preference.
    def effective_response
      response = recorded_response
      response if response&.plan_version_id == plan.current_plan_version_id
    end

    def effective_status
      status == "withdrawn" ? "withdrawn" : (effective_response&.decision || "pending")
    end

    def effective_human_decision
      response = effective_response
      response.decision if response&.actor_type == "human"
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
