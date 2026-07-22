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

## Brand the Slack app

Slack takes the name and icon shown above an unfurl from the app profile, not
from the `chat.unfurl` payload. In the app's **Basic Information → Display
Information** settings, use:

- **App name:** `CoPlan`
- **Short description:** `Collaborative engineering plans, reviewed by humans and refined by AI.`
- **App icon:** [`assets/coplan-slack-icon.png`](assets/coplan-slack-icon.png)
- **Background color:** `#010D27`

The icon is intentionally simpler than the in-product logo so the document and
conversation mark stays legible in Slack's small app avatar. The dark profile
color matches CoPlan's navigation chrome; unfurls use CoPlan blue, violet for
private plans, and slate for archived plans.

Any proxy must preserve the raw request body plus `X-Slack-Signature` and `X-Slack-Request-Timestamp`. The adapter verifies Slack's signature and timestamp before parsing the event. An edge rule that merely checks for the signature header is not a replacement for this verification.

This initial adapter supports one deployment-scoped Slack installation. Multi-workspace OAuth installation and token storage are outside its scope.
