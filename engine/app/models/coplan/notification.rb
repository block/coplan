module CoPlan
  class Notification < ApplicationRecord
    REASONS = %w[new_comment reply agent_response status_change mention].freeze

    belongs_to :user, class_name: "CoPlan::User"
    belongs_to :plan, class_name: "CoPlan::Plan"
    belongs_to :comment_thread, class_name: "CoPlan::CommentThread"
    belongs_to :comment, class_name: "CoPlan::Comment", optional: true

    validates :reason, presence: true, inclusion: { in: REASONS }

    scope :unread, -> { where(read_at: nil) }
    scope :read, -> { where.not(read_at: nil) }
    scope :newest_first, -> { order(created_at: :desc) }

    after_commit :enqueue_web_push_deliveries, on: :create

    def read?
      read_at.present?
    end

    def mark_read!
      update!(read_at: Time.current) unless read?
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id user_id plan_id comment_thread_id reason read_at created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[user plan comment_thread comment]
    end

    private

    # Fan-out one WebPushDeliveryJob per active subscription belonging to the
    # recipient. Quietly skips when Web Push isn't configured (host hasn't
    # set VAPID keys) or the recipient hasn't subscribed any browsers yet.
    def enqueue_web_push_deliveries
      return unless CoPlan.configuration.web_push_configured?

      user.web_push_subscriptions.find_each do |subscription|
        WebPushDeliveryJob.perform_later(
          notification_id: id,
          subscription_id: subscription.id
        )
      end
    end
  end
end
