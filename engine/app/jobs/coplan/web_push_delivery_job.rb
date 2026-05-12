require "web-push"

module CoPlan
  # Delivers one Notification's Web Push payload to one subscription.
  #
  # Per-subscription rather than per-notification so that a single bad
  # endpoint (rate limited, briefly down, etc.) doesn't block delivery to
  # the user's other devices, and so retries / backoff are scoped tightly.
  class WebPushDeliveryJob < ApplicationJob
    queue_as :default

    # SolidQueue retries everything else with backoff. We don't retry the
    # known terminal cases below: ExpiredSubscription / InvalidSubscription
    # are handled inside Deliver and surface as :expired.
    retry_on ::WebPush::PushServiceError, wait: :polynomially_longer, attempts: 5
    retry_on ::WebPush::TooManyRequests,  wait: :polynomially_longer, attempts: 5

    def perform(notification_id:, subscription_id:)
      notification = Notification.find_by(id: notification_id)
      return unless notification

      subscription = WebPushSubscription.find_by(id: subscription_id)
      return unless subscription

      payload = WebPush::PayloadForNotification.call(notification)
      result = WebPush::Deliver.call(subscription: subscription, payload: payload)
      subscription.destroy if result == :expired
    end
  end
end
