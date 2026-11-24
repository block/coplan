module Coplan
  class Notification < ApplicationRecord
    REASONS = %w[new_comment reply agent_response status_change mention review_requested review_response].freeze

    belongs_to :user, class_name: "Coplan::User"
    belongs_to :plan, class_name: "Coplan::Plan"
    belongs_to :comment_thread, class_name: "Coplan::CommentThread", optional: true
    belongs_to :review_request, optional: true
    belongs_to :comment, class_name: "Coplan::Comment", optional: true
    has_many :notification_deliveries, dependent: :delete_all

    validates :reason, presence: true, inclusion: { in: REASONS }
    validates :comment_thread, presence: true, unless: -> { review_notification? }
    validates :review_request, presence: true, if: :review_notification?

    def review_notification?
      reason.in?(%w[review_requested review_response])
    end

    scope :unread, -> { where(read_at: nil) }
    scope :read, -> { where.not(read_at: nil) }
    scope :newest_first, -> { order(created_at: :desc) }

    # Who caused this notification, for Notifications::FanoutBudget. Not
    # stored: it only decides whether this row's deliveries go out.
    attr_accessor :fanout_actor_id

    after_commit :enqueue_deliveries, on: :create

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

    # Web push goes to at most MAX_PER_USER most recently registered devices
    # for the recipient, including accounts already over the cap before it
    # was introduced. Quietly skips when Web Push isn't configured (host
    # hasn't set VAPID keys) or the recipient hasn't subscribed any browsers.
    def enqueue_deliveries
      subscriptions = Coplan.configuration.web_push_configured? ? user.web_push_subscriptions.for_delivery.to_a : []
      adapters = Coplan.configuration.notification_delivery_handlers.any?
      cost = subscriptions.size + (adapters ? 1 : 0)
      return if cost.zero?
      return unless Notifications::FanoutBudget.spend?(actor_id: fanout_actor_id, cost: cost)

      subscriptions.each do |subscription|
        WebPushDeliveryJob.perform_later(notification_id: id, subscription_id: subscription.id)
      end
      DispatchNotificationJob.perform_later(id) if adapters
    end
  end
end
