module CoPlan
  # An immutable fact about one version. Later edits and reassignment never
  # rewrite it. A change request points into the ordinary discussion system.
  class ReviewResponse < ApplicationRecord
    DECISIONS = %w[approved changes_requested].freeze
    ACTOR_TYPES = %w[human local_agent].freeze

    belongs_to :review_request
    belongs_to :plan_version
    belongs_to :user, class_name: "CoPlan::User"
    belongs_to :api_token, optional: true
    belongs_to :comment_thread, optional: true

    validates :decision, inclusion: { in: DECISIONS }
    validates :actor_type, inclusion: { in: ACTOR_TYPES }
    validates :agent_name, presence: true, if: -> { actor_type == "local_agent" }
    validates :agent_name, length: { maximum: 20 }, allow_nil: true
    validates :note, presence: true, if: -> { decision == "changes_requested" }
    validate :matches_request

    def readonly?
      persisted?
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id review_request_id plan_version_id user_id decision actor_type agent_name created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[review_request plan_version user comment_thread]
    end

    private

    def matches_request
      return unless review_request
      errors.add(:user, "must be the requested reviewer") if user_id != review_request.reviewer_id
      errors.add(:plan_version, "must belong to the reviewed plan") if plan_version && plan_version.plan_id != review_request.plan_id
      errors.add(:comment_thread, "must belong to the reviewed plan") if comment_thread && comment_thread.plan_id != review_request.plan_id
    end
  end
end
