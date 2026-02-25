require "rails_helper"

RSpec.describe SlackClient do
  let(:token) { "xoxb-test-token" }
  let(:client) { described_class.new(token: token) }
  let(:slack_web_client) { instance_double(Slack::Web::Client) }

  before do
    allow(Slack::Web::Client).to receive(:new).and_return(slack_web_client)
  end

  describe "#send_dm" do
    let(:email) { "author@example.com" }
    let(:text) { "Hello from tests" }

    it "looks up user by email and sends message to their user ID" do
      allow(slack_web_client).to receive(:users_lookupByEmail)
        .with(email: email)
        .and_return({ "user" => { "id" => "U123" } })
      allow(slack_web_client).to receive(:chat_postMessage)

      client.send_dm(email: email, text: text)

      expect(slack_web_client).to have_received(:chat_postMessage).with(
        channel: "U123", text: text, mrkdwn: true
      )
    end

    it "raises PermanentError for permanent Slack failures" do
      allow(slack_web_client).to receive(:users_lookupByEmail)
        .and_raise(Slack::Web::Api::Errors::SlackError.new("users_not_found"))

      expect { client.send_dm(email: email, text: text) }
        .to raise_error(SlackClient::PermanentError, "users_not_found")
    end

    it "raises Error (retryable) for transient Slack failures" do
      allow(slack_web_client).to receive(:users_lookupByEmail)
        .and_raise(Slack::Web::Api::Errors::SlackError.new("ratelimited"))

      expect { client.send_dm(email: email, text: text) }
        .to raise_error(SlackClient::Error) { |e| expect(e).not_to be_a(SlackClient::PermanentError) }
    end

    it "raises PermanentError when user ID is nil" do
      allow(slack_web_client).to receive(:users_lookupByEmail)
        .and_return({ "user" => { "id" => nil } })

      expect { client.send_dm(email: email, text: text) }
        .to raise_error(SlackClient::PermanentError, /No Slack user found/)
    end
  end

  describe ".configured?" do
    it "returns true when bot token is present" do
      allow(described_class).to receive(:bot_token).and_return("xoxb-token")
      expect(described_class).to be_configured
    end

    it "returns false when bot token is nil" do
      allow(described_class).to receive(:bot_token).and_return(nil)
      expect(described_class).not_to be_configured
    end
  end
end
