module CoPlan
  module Slack
    class WebClient
      class PermanentError < StandardError; end
      class RetryableError < StandardError; end
      class RateLimitedError < RetryableError
        attr_reader :retry_after

        def initialize(retry_after)
          @retry_after = retry_after.to_i
          super("Slack rate limited the request")
        end
      end

      PERMANENT_ERRORS = %w[
        access_denied account_inactive cannot_find_channel cannot_find_message cannot_find_service
        cannot_parse_attachment cannot_unfurl_message cannot_unfurl_url channel_not_found
        ekm_access_denied invalid_arguments invalid_auth invalid_blocks invalid_source
        invalid_unfurl_id invalid_unfurls_format is_bot missing_channel missing_scope
        missing_source missing_ts missing_unfurl_id missing_unfurls no_permission not_authed
        not_in_channel team_access_not_granted token_expired token_revoked
      ].freeze

      def initialize(token:, client: nil)
        @client = client || ::Slack::Web::Client.new(token: token)
      end

      def chat_unfurl(**arguments)
        @client.chat_unfurl(**arguments)
      rescue ::Slack::Web::Api::Errors::TooManyRequestsError => error
        raise RateLimitedError.new(error.retry_after)
      rescue ::Slack::Web::Api::Errors::SlackError => error
        code = error.message
        raise(PERMANENT_ERRORS.include?(code) ? PermanentError : RetryableError, error.message)
      rescue Faraday::Error, Timeout::Error => error
        raise RetryableError, error.message
      end
    end
  end
end
