require "rails_helper"

RSpec.describe CoPlan::Slack::WebClient do
  let(:delegate) { double("Slack client") }
  subject(:client) { described_class.new(token: "token", client: delegate) }

  it "delegates successful unfurls" do
    expect(delegate).to receive(:chat_unfurl).with(channel: "C", ts: "1", unfurls: {}).and_return("ok" => true)
    expect(client.chat_unfurl(channel: "C", ts: "1", unfurls: {})).to eq("ok" => true)
  end

  it "classifies transport failures as retryable" do
    allow(delegate).to receive(:chat_unfurl).and_raise(Faraday::ConnectionFailed.new("down"))
    expect { client.chat_unfurl }.to raise_error(described_class::RetryableError, "down")
  end

  it "exposes retry-after on rate limits" do
    response = double(headers: { "retry-after" => "7" })
    error = ::Slack::Web::Api::Errors::TooManyRequestsError.new(response)
    allow(delegate).to receive(:chat_unfurl).and_raise(error)
    expect { client.chat_unfurl }.to raise_error(described_class::RateLimitedError) { |raised| expect(raised.retry_after).to eq(7) }
  end

  it "classifies Slack API responses as permanent or retryable" do
    allow(delegate).to receive(:chat_unfurl).and_raise(::Slack::Web::Api::Errors::SlackError.new("invalid_blocks"))
    expect { client.chat_unfurl }.to raise_error(described_class::PermanentError)

    allow(delegate).to receive(:chat_unfurl).and_raise(::Slack::Web::Api::Errors::SlackError.new("internal_error"))
    expect { client.chat_unfurl }.to raise_error(described_class::RetryableError)
  end
end
