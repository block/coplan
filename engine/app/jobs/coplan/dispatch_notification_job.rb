module CoPlan
  class DispatchNotificationJob < ApplicationJob
    queue_as :default

    def perform(notification_id)
      notification = Notification.find_by(id: notification_id)
      return unless notification

      CoPlan.configuration.notification_delivery_handlers.each { |handler| handler.call(notification) }
    end
  end
end
