class SlackClient
  class Error < StandardError; end
  class PermanentError < Error; end

  PERMANENT_ERRORS = %w[
    users_not_found channel_not_found not_authed invalid_auth
    missing_scope account_inactive token_revoked
  ].freeze

  def self.send_dm(...)
    new.send_dm(...)
  end

  def initialize(token: self.class.bot_token)
    @client = Slack::Web::Client.new(token: token)
  end

  def send_dm(email:, text:)
    user_id = lookup_user_id(email)
    @client.chat_postMessage(channel: user_id, text: text, mrkdwn: true)
  rescue Slack::Web::Api::Errors::SlackError => e
    Rails.logger.error("[SlackClient] Slack API error: #{e.message}")
    if PERMANENT_ERRORS.include?(e.message)
      raise PermanentError, e.message
    else
      raise Error, e.message
    end
  end

  def self.bot_token
    Rails.application.credentials.dig(:slack, :bot_token) || ENV["SLACK_BOT_TOKEN"]
  end

  def self.configured?
    bot_token.present?
  end

  private

  def lookup_user_id(email)
    response = @client.users_lookupByEmail(email: email)
    user_id = response.dig("user", "id")
    raise PermanentError, "No Slack user found for #{email}" if user_id.nil?
    user_id
  end
end
