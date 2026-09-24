module CoPlan
  class DispatchNotificationJob < ApplicationJob
    class AdapterUnavailable < StandardError; end

    queue_as :default
    retry_on AdapterUnavailable, wait: 1.minute, attempts: 60

    def perform(notification_id)
      notification = Notification.find_by(id: notification_id)
      return unless notification

      handlers = CoPlan.configuration.notification_delivery_handlers
      raise AdapterUnavailable, "No notification delivery adapters are loaded" if handlers.empty?

      handlers.each { |handler| handler.call(notification) }
    end
  end
end
