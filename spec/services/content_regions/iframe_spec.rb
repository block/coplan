require "rails_helper"
RSpec.describe CoPlan::ContentRegions::Iframe do
  def block(src, rest = '')
    described_class.call(%(::: {.iframe src="#{src}"#{rest} /}))
  end
  it "defaults sizes, checks HTTPS URLs and matches approved hosts exactly" do
    CoPlan::EmbedDomain.create!(hostname: "embed.example.com")
    expect(block('https://embed.example.com/view').allowed?).to be(true)
    expect(block('https://sub.embed.example.com/view').allowed?).to be(false)
    expect(block('https://embed.example.com.evil.test/view').allowed?).to be(false)
    expect(block('https://embed.example.com/view').allowed?(host: 'embed.example.com')).to be(false)
    [ 'http://embed.example.com/view', '//embed.example.com/view', 'javascript:alert(1)', 'https://user@embed.example.com', 'https://embed.example.com:8443/view', 'https://embed.example.com\\@evil.test' ].each do |src|
      expect(block(src).allowed?).to be(false)
    end
  end
  it "validates dimensions and never accepts author-controlled iframe privileges" do
    expect(block('https://embed.example.com', ' width="80%" height="600"').valid?).to be(true)
    [ ' width="101%"', ' width="10; color:red"', ' height="0"', ' height="9000"', ' width="9000"', ' title=""' ].each do |rest|
      expect(block('https://embed.example.com', rest).valid?).to be(false)
    end
    expect(block('https://embed.example.com', ' sandbox="allow-same-origin"')).to be_nil
    expect(block('https://embed.example.com', ' src="https://evil.test"')).to be_nil
    expect(block('https://embed.example.com', ' title="A &quot;quoted&quot; title"').attributes['title']).to eq('A "quoted" title')
  end
end
