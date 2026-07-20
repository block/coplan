# CoPlan Slack adapter

Add the optional adapter alongside `coplan-engine`:

```ruby
gem "coplan-slack"
```

When developing from a CoPlan source checkout, use `gem "coplan-slack", path: "integrations/slack"` instead. Mount the adapter before the core engine:

```ruby
mount CoPlan::Slack::Engine => "/integrations/slack", as: :coplan_slack
mount CoPlan::Engine => "/", as: :coplan
```

Configure the deployment's Slack app and canonical CoPlan URL:

```ruby
CoPlan::Slack.configure do |config|
  config.signing_secret = ENV["SLACK_SIGNING_SECRET"]
  config.bot_token = ENV["SLACK_BOT_TOKEN"]
  config.base_url = ENV["COPLAN_BASE_URL"] # e.g. https://coplan.example.com/
end
```

Point Slack's Events API request URL at `/integrations/slack/events`. Configure the `links:read` and `links:write` bot scopes, subscribe to `link_shared`, and register the CoPlan domain under **App unfurl domains**. The endpoint must be reachable from Slack over HTTPS.

Any proxy must preserve the raw request body plus `X-Slack-Signature` and `X-Slack-Request-Timestamp`. The adapter verifies Slack's signature and timestamp before parsing the event. An edge rule that merely checks for the signature header is not a replacement for this verification.

This initial adapter supports one deployment-scoped Slack installation. Multi-workspace OAuth installation and token storage are outside its scope.
