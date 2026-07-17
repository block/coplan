module CoPlan
  module Slack
    class EventsController < ApplicationController
      def create
        config = CoPlan::Slack.configuration
        return head :not_found unless config.configured?

        ::Slack::Events::Request.new(request, signing_secret: config.signing_secret).verify!
        payload = JSON.parse(request.raw_post)
        return render json: { challenge: payload["challenge"] } if payload["type"] == "url_verification"

        event = payload["event"]
        if event&.dig("type") == "link_shared"
          UnfurlJob.perform_later(
            event,
            {
              "event_id" => payload["event_id"],
              "retry_num" => request.headers["X-Slack-Retry-Num"],
              "retry_reason" => request.headers["X-Slack-Retry-Reason"]
            }
          )
        end
        head :ok
      rescue ::Slack::Events::Request::InvalidSignature,
             ::Slack::Events::Request::TimestampExpired,
             ::Slack::Events::Request::MissingSigningSecret
        head :unauthorized
      rescue JSON::ParserError
        head :bad_request
      end
    end
  end
end
