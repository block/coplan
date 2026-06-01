module AnalyticsHelpers
  # Captures all analytics events emitted during the block by swapping in a
  # collecting handler on CoPlan.configuration.track_event. Returns an array of
  # [event_name_string, payload_hash] tuples, in emission order.
  #
  # Restores the previous handler even if the block raises.
  def capture_analytics_events
    events = []
    previous = CoPlan.configuration.track_event
    CoPlan.configuration.track_event = ->(event, payload) { events << [event, payload] }
    yield
    events
  ensure
    CoPlan.configuration.track_event = previous
  end
end

RSpec.configure do |config|
  config.include AnalyticsHelpers
end
