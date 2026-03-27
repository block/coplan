module CoPlan
  class PlanViewer < ApplicationRecord
    STALE_THRESHOLD = 45.seconds

    belongs_to :plan
    belongs_to :user, class_name: "CoPlan::User"

    scope :active, -> { where(last_seen_at: STALE_THRESHOLD.ago..) }

    def self.track(plan:, user:)
      record = find_or_initialize_by(plan: plan, user: user)
      record.update!(last_seen_at: Time.current)
      record
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def self.expire(plan:, user:)
      where(plan: plan, user: user).update_all(last_seen_at: STALE_THRESHOLD.ago - 1.second)
    end

    def self.active_viewers_for(plan)
      active.where(plan: plan).joins(:user).includes(:user).order("coplan_users.name").map(&:user)
    end
  end
end
