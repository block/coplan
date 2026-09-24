require "slack-ruby-client"
require "coplan"
require "coplan/slack/version"
require "coplan/slack/configuration"
require "coplan/slack/engine"

module CoPlan
  module Slack
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
        if configuration.notifications_enabled && !CoPlan.configuration.notification_delivery_handlers.include?(notification_delivery_handler)
          CoPlan.configuration.notification_delivery_handlers << notification_delivery_handler
        end
      end

      def notification_delivery_handler
        @notification_delivery_handler ||= ->(notification) {
          next unless configuration.notifications_enabled
          next unless notification.reason.in?(%w[new_comment reply])

          unless configuration.notifications_configured?
            raise ArgumentError, "CoPlan Slack notifications require bot_token and base_url"
          end

          delivery = CoPlan::NotificationDelivery.create_or_find_by!(notification: notification, channel: "slack") do |record|
            record.status = "pending"
          end
          next unless delivery.status == "pending"

          NotificationDeliveryJob.debounce(
            key: "#{notification.user_id}:#{notification.comment_thread_id}",
            event_at: delivery.created_at
          )
        }
      end
    end
  end
end
