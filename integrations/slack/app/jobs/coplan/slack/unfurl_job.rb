module CoPlan
  module Slack
    class UnfurlJob < ActiveJob::Base
      queue_as :default
      retry_on WebClient::RetryableError, wait: :polynomially_longer, attempts: 4
      discard_on WebClient::PermanentError

      def perform(event, delivery = {})
        config = CoPlan::Slack.configuration
        return unless config.configured?

        unfurls = Array(event["links"]).each_with_object({}) do |link, result|
          exact_url = link["url"]
          preview = CoPlan::LinkPreviews.resolve(url: exact_url, base_url: config.base_url)
          result[exact_url] = Renderer.call(preview, url: exact_url) if preview
        end
        return if unfurls.empty?

        args = { unfurls: unfurls }
        if event["source"] == "composer" && event["unfurl_id"].present?
          args.merge!(unfurl_id: event["unfurl_id"], source: event["source"])
        else
          args.merge!(channel: event.fetch("channel"), ts: event.fetch("message_ts"))
        end
        WebClient.new(token: config.bot_token).chat_unfurl(**args)

        CoPlan::Analytics.track(
          "slack_link_unfurled",
          event_id: delivery["event_id"],
          retry_num: delivery["retry_num"],
          retry_reason: delivery["retry_reason"],
          link_count: unfurls.size
        )
      rescue WebClient::RateLimitedError => error
        raise if executions >= 4

        retry_job(wait: [ [ error.retry_after, 1 ].max, 60 ].min.seconds)
      end
    end
  end
end
