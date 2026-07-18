require "rails_helper"

RSpec.describe CoPlan::Slack::Renderer do
  it "escapes mrkdwn and adds an image accessory and composer title" do
    preview = CoPlan::LinkPreview.new(kind: "plan", external_id: "id", canonical_url: "https://example.test/p", title: "A < B & C", description: "> hello", context: "Live & ready", image_url: "https://example.test/i.png", cache_key: "x")
    result = described_class.call(preview, url: "https://example.test/p?thread=123&view=full")
    expect(result[:blocks][0][:text][:text]).to include("A &lt; B &amp; C", "&gt; hello")
    expect(result[:blocks][1][:elements][0][:text]).to eq("Live &amp; ready")
    expect(result[:blocks][0][:text][:text]).to include("https://example.test/p?thread=123&amp;view=full")
    expect(result[:blocks][0][:accessory][:image_url]).to eq(preview.image_url)
    expect(result[:fallback]).to include(preview.title)
    expect(result.dig(:preview, :title, :text)).to eq(preview.title)
  end
end
