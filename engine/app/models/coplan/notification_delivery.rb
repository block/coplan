module CoPlan
  class NotificationDelivery < ApplicationRecord
    CHANNELS = %w[slack].freeze
    STATUSES = %w[pending delivered skipped failed].freeze

    belongs_to :notification

    validates :channel, presence: true, inclusion: { in: CHANNELS }
    validates :status, presence: true, inclusion: { in: STATUSES }

    scope :pending, -> { where(status: "pending") }

    def self.ransackable_attributes(auth_object = nil)
      %w[id notification_id channel status sent_at external_id error_code created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[notification]
    end
  end
end
