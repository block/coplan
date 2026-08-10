module CoPlan
  module Api
    module V1
      # The agent-facing event inbox. Agents (or their bridge daemons) on
      # laptops behind NAT can't be pushed to, so delivery is pull-based
      # with two modes on one endpoint:
      #
      #   Long-poll (default):  GET /api/v1/agent/events?wait=25&cursor=<id>
      #     Returns as soon as an event is available, or after `wait`
      #     seconds with an empty list. Plain JSON, works with curl in a
      #     loop through any proxy.
      #
      #   SSE:  same URL with Accept: text/event-stream
      #     Holds the response open and streams events as they land, with
      #     heartbeat comments so intermediaries don't kill the socket.
      #
      # Both forms block on AgentEventBus rather than polling, and both
      # respect its held-connection budget: an attached agent must never
      # be able to starve ordinary page requests of Rack threads. Over
      # budget, long-poll answers immediately with `throttled: true` and
      # SSE is refused with 503 + Retry-After.
      #
      # Cursoring: event ids are UUIDv7 (time-ordered), so `cursor` is
      # simply the last event id the client has seen. Without a cursor you
      # get unacked events, so a crashed client picks up where it left off.
      # Delivery is at-least-once — ack after successful processing.
      class AgentEventsController < BaseController
        include ActionController::Live

        MAX_WAIT = 55
        SSE_LIFETIME = 5.minutes
        HEARTBEAT_INTERVAL = 15

        def index
          unless @api_token
            render json: { error: "Agent events require token authentication" }, status: :forbidden
            return
          end

          if request.headers["Accept"].to_s.include?("text/event-stream")
            stream_events
          else
            long_poll_events
          end
        end

        # POST /api/v1/agent/events/ack {"cursor": "<event id>"}
        # Marks everything up to and including the cursor as processed.
        def ack
          unless @api_token
            render json: { error: "Agent events require token authentication" }, status: :forbidden
            return
          end

          cursor = params[:cursor].to_s
          if cursor.blank?
            render json: { error: "cursor is required" }, status: :unprocessable_content
            return
          end

          acked = AgentEvent.for_token(@api_token).pending
            .where("id <= ?", cursor)
            .update_all(acked_at: Time.current)

          render json: { acked: acked }
        end

        private

        # Holding a thread for `wait` seconds is only acceptable while the
        # server has threads to spare; over budget we answer immediately
        # and let the client come back, which is strictly better than
        # making everyone's page loads queue behind attached agents.
        def long_poll_events
          AgentEventBus.with_slot do |granted|
            wait = granted ? params[:wait].to_i.clamp(0, MAX_WAIT) : 0
            deadline = Time.current + wait

            loop do
              events = fetch_events
              if events.any? || Time.current >= deadline
                render json: {
                  events: events.map(&:as_api_json),
                  cursor: events.last&.id || params[:cursor],
                  **(granted ? {} : { throttled: true })
                }
                return
              end
              AgentEventBus.wait(@api_token.id, timeout: deadline - Time.current)
            end
          end
        end

        def stream_events
          AgentEventBus.with_slot do |granted|
            unless granted
              response.headers["Retry-After"] = "5"
              render json: {
                error: "Too many attached agents on this server",
                capacity: AgentEventBus.capacity,
                fallback: "Retry, or use the long-poll form of this endpoint (omit the text/event-stream Accept header)."
              }, status: :service_unavailable
              return
            end

            write_event_stream
          end
        end

        def write_event_stream
          response.headers["Content-Type"] = "text/event-stream"
          response.headers["Cache-Control"] = "no-cache"
          response.headers["X-Accel-Buffering"] = "no"

          cursor = params[:cursor].presence
          deadline = Time.current + SSE_LIFETIME
          last_heartbeat = Time.current

          while Time.current < deadline
            events = fetch_events(cursor: cursor)
            events.each do |event|
              response.stream.write("id: #{event.id}\nevent: #{event.event_type}\ndata: #{event.as_api_json.to_json}\n\n")
              cursor = event.id
            end

            if Time.current - last_heartbeat > HEARTBEAT_INTERVAL
              response.stream.write(": heartbeat\n\n")
              last_heartbeat = Time.current
            end

            AgentEventBus.wait(@api_token.id, timeout: [HEARTBEAT_INTERVAL, deadline - Time.current].min)
          end
        rescue IOError, ActionController::Live::ClientDisconnected
          # Client went away — normal for a streaming endpoint.
        ensure
          response.stream.close
        end

        def fetch_events(cursor: params[:cursor].presence)
          scope = AgentEvent.for_token(@api_token)
          scope = cursor ? scope.after(cursor) : scope.pending
          scope.oldest_first.limit(100).to_a
        end
      end
    end
  end
end
