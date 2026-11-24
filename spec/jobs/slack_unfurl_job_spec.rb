require "rails_helper"

RSpec.describe Coplan::Slack::UnfurlJob do
  let(:client) { instance_double(Coplan::Slack::WebClient) }
  let!(:plan) { create(:plan, :published) }

  before do
    config = Coplan::Slack.configuration
    config.signing_secret = "secret"
    config.bot_token = "token"
    config.base_url = "https://coplan.example.test"
    allow(Coplan::Slack::WebClient).to receive(:new).and_return(client)
  end

  it "batches posted-message previews under exact URLs and skips unsupported links" do
    other_plan = create(:plan, :published)
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

  it "keeps the discussion target in the preview's clickable title" do
    thread = create(:comment_thread, plan: plan)
    exact = "https://coplan.example.test#{plan_page_path(plan, thread: thread.id)}"
    expect(client).to receive(:chat_unfurl) do |unfurls:, **|
      expect(unfurls.fetch(exact).dig(:blocks, 0, :text, :text)).to include("<#{exact}|")
    end

    described_class.perform_now(
      "channel" => "C1", "message_ts" => "123.4", "links" => [ { "url" => exact } ])
  end

  %w[composer conversations_history].each do |source|
    it "does not call Slack for private-only #{source} links" do
      plan.update!(visibility: "draft")
      archived = create(:plan, :draft, archived_at: Time.current)
      expect(client).not_to receive(:chat_unfurl)

      described_class.perform_now(
        "source" => source, "unfurl_id" => "U1", "channel" => "C1", "message_ts" => "123.4",
        "links" => [ plan, archived ].map { |private_plan| { "url" => "https://coplan.example.test/plans/#{private_plan.id}" } })
    end

    it "only unfurls published plans in a mixed #{source} batch" do
      draft = create(:plan, :draft)
      exact = "https://coplan.example.test/plans/#{plan.id}"
      expect(client).to receive(:chat_unfurl) do |unfurls:, **|
        expect(unfurls.keys).to eq([ exact ])
        expect(unfurls.fetch(exact).dig(:blocks, 0, :text, :text)).to include(plan.title)
      end

      described_class.perform_now(
        "source" => source, "unfurl_id" => "U1", "channel" => "C1", "message_ts" => "123.4",
        "links" => [ { "url" => "https://coplan.example.test/plans/#{draft.id}" }, { "url" => exact } ])
    end
  end

  it "does not call Slack when every link is unsupported" do
    expect(client).not_to receive(:chat_unfurl)
    described_class.perform_now("links" => [ { "url" => "https://elsewhere.test/x" } ])
  end
end
