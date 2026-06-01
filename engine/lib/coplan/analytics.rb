module CoPlan
  # Thin facade for the configurable analytics hook. Call sites use
  # `CoPlan::Analytics.track("event_name", user:, **props)`;
  # the host wires `CoPlan.configuration.track_event` to a destination
  # (a MySQL events table, Snowflake, Datadog, etc.). Default is no-op.
  #
  # Errors in the host handler are swallowed and reported via
  # `CoPlan.configuration.error_reporter` so a broken analytics sink
  # never breaks the user request that triggered the event.
  module Analytics
    def self.track(event, user: nil, **properties)
      handler = CoPlan.configuration.track_event
      return unless handler

      event_name = event.to_s
      payload = {
        event: event_name,
        timestamp: Time.current.iso8601,
        user_id: user&.id,
        properties: properties
      }

      handler.call(event_name, payload)
    rescue => e
      reporter = CoPlan.configuration.error_reporter
      reporter&.call(e, { coplan_analytics_event: event.to_s })
      nil
    end
  end
end
