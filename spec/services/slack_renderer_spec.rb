require "rails_helper"

RSpec.describe CoPlan::Slack::Renderer do
  it "renders a branded published-plan unfurl" do
    preview = CoPlan::LinkPreview.new(kind: "plan", external_id: "id", canonical_url: "https://example.test/p", title: "A < B & C", description: "> hello", context: "Live & ready · by Ada", image_url: "https://example.test/i.png", author_name: "Ada", author_avatar_url: "https://example.test/ada.png", cache_key: "x")
    result = described_class.call(preview, url: "https://example.test/p?thread=123&view=full")
    expect(result[:blocks][0][:text][:text]).to include("A &lt; B &amp; C", "&gt; hello")
    expect(result[:blocks][1][:elements][0]).to eq(type: "image", image_url: preview.author_avatar_url, alt_text: "Ada")
    expect(result[:blocks][1][:elements][1][:text]).to eq("*Ada* · Live &amp; ready")
    expect(result[:blocks][0][:text][:text]).to include("https://example.test/p?thread=123&amp;view=full")
    expect(result[:blocks][0][:accessory][:image_url]).to eq(preview.image_url)
    expect(result[:color]).to eq("#136FF5")
    expect(result[:fallback]).to include(preview.title)
    expect(result.dig(:preview, :title, :text)).to eq(preview.title)
  end

  it "visually distinguishes private and archived plans" do
    private_preview = CoPlan::LinkPreview.new(kind: "plan", external_id: "id", canonical_url: "https://example.test/p", title: "Private", description: nil, context: "Private · EDD · by Ada", image_url: nil, author_name: "Ada", author_avatar_url: nil, cache_key: "x")
    archived_preview = private_preview.with(title: "Archived", context: "Archived · EDD · by Ada")

    private_result = described_class.call(private_preview)
    archived_result = described_class.call(archived_preview)

    expect(private_result[:color]).to eq("#8C4AF6")
    expect(private_result.dig(:blocks, 1, :elements, 0, :text)).to eq("*Ada* · EDD · 🔒 Private")
    expect(archived_result[:color]).to eq("#64748B")
    expect(archived_result.dig(:blocks, 1, :elements, 0, :text)).to eq("*Ada* · EDD · 📦 Archived")
  end
end
