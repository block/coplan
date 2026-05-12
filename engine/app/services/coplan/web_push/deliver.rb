require "web-push"

module CoPlan
  module WebPush
    # Sends a single push payload to a single browser subscription using the
    # configured VAPID key pair. Returns one of:
    #
    #   :delivered  - push service accepted the message (2xx)
    #   :expired    - subscription is gone (404 / 410); caller should destroy it
    #
    # Anything else (transient 5xx, rate limiting, network errors) raises so
    # SolidQueue can retry with backoff.
    class Deliver
      def self.call(subscription:, payload:)
        new(subscription: subscription, payload: payload).call
      end

      def initialize(subscription:, payload:)
        @subscription = subscription
        @payload = payload
      end

      def call
        unless CoPlan.configuration.web_push_configured?
          raise ConfigurationError, "Web Push VAPID keys are not configured"
        end

        ::WebPush.payload_send(
          endpoint: @subscription.endpoint,
          p256dh: @subscription.p256dh_key,
          auth: @subscription.auth_key,
          message: @payload.to_json,
          vapid: vapid_options,
          ttl: 24 * 60 * 60, # 24h — push service drops the message after this
          urgency: "normal"
        )

        @subscription.record_delivery!
        :delivered
      rescue ::WebPush::InvalidSubscription, ::WebPush::ExpiredSubscription
        # Browser unsubscribed or endpoint was rotated. Tell the caller to
        # destroy the row so we don't keep trying.
        :expired
      end

      class ConfigurationError < StandardError; end

      private

      def vapid_options
        {
          subject: CoPlan.configuration.vapid_subject,
          public_key: CoPlan.configuration.vapid_public_key,
          private_key: CoPlan.configuration.vapid_private_key
        }
      end
    end
  end
end
