CoPlan::Slack.configure do |config|
  config.signing_secret = ENV["SLACK_SIGNING_SECRET"]
  config.bot_token = ENV["SLACK_BOT_TOKEN"]
  config.base_url = ENV["COPLAN_BASE_URL"]
end
