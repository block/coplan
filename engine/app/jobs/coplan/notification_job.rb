module CoPlan
  class NotificationJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    def perform(event, payload)
      CoPlan.configuration.notification_handler&.call(event.to_sym, payload.symbolize_keys)
    end
  end
end
