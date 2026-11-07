require "rails_helper"

RSpec.describe CoPlan::LinkScrubber do
  it "allows application anchors without allowing executable schemes, handlers, or image sources" do
    scrubber = described_class.new
    scrubber.tags = %w[a img]
    scrubber.attributes = %w[href src]
    html = '<a href="codex://threads/123" onclick="alert(1)">chat</a><img src="codex://image">' \
      '<a href="java&#x09;script:alert(1)">bad</a><a href="JAVASCRIPT:alert(1)">bad</a>' \
      '<a href="data:text/html,bad">bad</a><a href="vbscript:bad">bad</a><a href="blob:https://example.com/123">bad</a>'
    result = Rails::HTML5::SafeListSanitizer.new.sanitize(html, scrubber: scrubber)
    fragment = Nokogiri::HTML.fragment(result)
    expect(fragment.css("a[href]").map { |a| a["href"] }).to eq([ "codex://threads/123" ])
    expect(fragment.css("img[src], [onclick]")).to be_empty
  end
end
