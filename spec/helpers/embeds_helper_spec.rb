require "rails_helper"
RSpec.describe CoPlan::MarkdownHelper, type: :helper do
  let(:marker) { '::: {.iframe src="https://embed.example.com/view?a=1&amp;b=2" title="Example" width="80%" height="600" /}' }
  def render(source)
    Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(source, interactive: false))
  end
  it "renders only approved content blocks with fixed sandbox and permissions" do
    CoPlan::EmbedDomain.create!(hostname: 'embed.example.com')
    frame = render(marker).at_css('iframe')
    expect(frame['src']).to eq('https://embed.example.com/view?a=1&b=2')
    expect(frame['title']).to eq('Example')
    expect(frame['sandbox']).to eq('allow-scripts allow-forms allow-same-origin')
    expect(frame['referrerpolicy']).to eq('strict-origin-when-cross-origin')
    expect(frame['style']).to eq('width: 80%')
    expect(frame['height']).to eq('600')
    expect(render(marker).css('[data-sourcepos]')).to be_empty
  end
  it "does not give an approved frame access to the application origin" do
    CoPlan::EmbedDomain.create!(hostname: 'embed.example.com')
    allow(helper.request).to receive(:host).and_return('embed.example.com')
    expect(render(marker).css('iframe')).to be_empty
  end
  it "shows unavailable embeds without loading their URL, including after revocation" do
    expect(render(marker).css('iframe')).to be_empty
    domain = CoPlan::EmbedDomain.create!(hostname: 'embed.example.com')
    expect(render(marker).css('iframe').size).to eq(1)
    domain.destroy!
    expect(render(marker).css('iframe')).to be_empty
    expect(render(marker).text).to include('Embedded page unavailable')
  end
  it "keeps examples and arbitrary raw HTML from creating frames" do
    CoPlan::EmbedDomain.create!(hostname: 'embed.example.com')
    [ "`#{marker}`", "```markdown\n#{marker}\n```", "> #{marker}", "- #{marker}", '<iframe src="https://embed.example.com/view"></iframe>' ].each do |source|
      expect(render(source).css('iframe')).to be_empty
    end
  end
end
