require "rails_helper"

RSpec.describe CoPlan::Slack::UnfurlJob do
  let(:client) { instance_double(CoPlan::Slack::WebClient) }
  let!(:plan) { create(:plan) }

  before do
    config = CoPlan::Slack.configuration
    config.signing_secret = "secret"
    config.bot_token = "token"
    config.base_url = "https://coplan.example.test"
    allow(CoPlan::Slack::WebClient).to receive(:new).and_return(client)
  end

  it "batches posted-message previews under exact URLs and skips unsupported links" do
    other_plan = create(:plan)
    exact = "https://coplan.example.test/plans/#{plan.id}?from=slack"
    other = "https://coplan.example.test/plans/#{other_plan.id}#goals"
    expect(client).to receive(:chat_unfurl) do |channel:, ts:, unfurls:|
      expect([ channel, ts ]).to eq(%w[C1 123.4])
      expect(unfurls.keys).to eq([ exact, other ])
      expect(unfurls.fetch(exact).dig(:blocks, 0, :text, :text)).to include(exact)
    end
    described_class.perform_now(
      {
        "source" => "conversations_history",
        "unfurl_id" => "posted-events-also-have-this",
        "channel" => "C1",
        "message_ts" => "123.4",
        "links" => [ { "url" => exact }, { "url" => other }, { "url" => "https://elsewhere.test/x" } ]
      },
      { "event_id" => "Ev1" }
    )
  end

  it "addresses composer previews with unfurl_id and source" do
    exact = "https://coplan.example.test/plans/#{plan.id}"
    expect(client).to receive(:chat_unfurl).with(hash_including(unfurl_id: "U1", source: "composer"))
    described_class.perform_now("unfurl_id" => "U1", "source" => "composer", "links" => [ { "url" => exact } ])
  end

  it "does not call Slack when every link is unsupported" do
    expect(client).not_to receive(:chat_unfurl)
    described_class.perform_now("links" => [ { "url" => "https://elsewhere.test/x" } ])
  end
end
