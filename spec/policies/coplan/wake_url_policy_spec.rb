require "rails_helper"

RSpec.describe CoPlan::WakeUrlPolicy do
  around do |example|
    # The test env installs a permissive policy; nil it out so these
    # examples exercise the engine default.
    original = CoPlan.configuration.wake_url_policy
    CoPlan.configuration.wake_url_policy = nil
    example.run
  ensure
    CoPlan.configuration.wake_url_policy = original
  end

  def allowed_for(addresses)
    allow(Resolv).to receive(:getaddresses).with("agents.example.com").and_return(addresses)
    described_class.allowed?(URI.parse("https://agents.example.com/wake"))
  end

  it "allows a host resolving to public address space" do
    expect(allowed_for([ "93.184.216.34" ])).to be(true)
  end

  it "refuses loopback" do
    expect(allowed_for([ "127.0.0.1" ])).to be(false)
  end

  it "refuses RFC1918 space" do
    expect(allowed_for([ "10.1.2.3" ])).to be(false)
    expect(allowed_for([ "172.16.0.9" ])).to be(false)
    expect(allowed_for([ "192.168.1.1" ])).to be(false)
  end

  it "refuses the cloud metadata address" do
    expect(allowed_for([ "169.254.169.254" ])).to be(false)
  end

  it "refuses IPv6 loopback and private ranges" do
    expect(allowed_for([ "::1" ])).to be(false)
    expect(allowed_for([ "fd00::1" ])).to be(false)
    expect(allowed_for([ "fe80::1" ])).to be(false)
  end

  # One public A record must not launder a private one — the attacker
  # controls the DNS answer, and the POST goes wherever it points.
  it "refuses a host with any private address among its answers" do
    expect(allowed_for([ "93.184.216.34", "10.0.0.5" ])).to be(false)
  end

  it "refuses a host that does not resolve at all" do
    expect(allowed_for([])).to be(false)
  end

  it "refuses when resolution errors" do
    allow(Resolv).to receive(:getaddresses).and_raise(Resolv::ResolvError)

    expect(described_class.allowed?(URI.parse("https://agents.example.com/wake"))).to be(false)
  end

  it "refuses an unparseable resolver answer rather than excusing it" do
    expect(allowed_for([ "not-an-address" ])).to be(false)
  end

  it "defers entirely to a configured host policy" do
    CoPlan.configuration.wake_url_policy = ->(uri) { uri.host == "trusted.internal" }

    expect(described_class.allowed?(URI.parse("http://trusted.internal/wake"))).to be(true)
    expect(described_class.allowed?(URI.parse("http://other.internal/wake"))).to be(false)
  end

  describe ".vetted_addresses" do
    # Callers that go on to connect must pin to one of these — resolving
    # again at connect time reopens the rebinding window.
    it "returns the vetted addresses for a public host" do
      allow(Resolv).to receive(:getaddresses).with("agents.example.com").and_return([ "93.184.216.34" ])

      expect(described_class.vetted_addresses(URI.parse("https://agents.example.com/wake")))
        .to eq([ "93.184.216.34" ])
    end

    it "returns nil for a refused host" do
      allow(Resolv).to receive(:getaddresses).with("agents.example.com").and_return([ "10.0.0.5" ])

      expect(described_class.vetted_addresses(URI.parse("https://agents.example.com/wake"))).to be_nil
    end

    it "returns :unpinned when a custom policy allows — it vets URIs, not addresses" do
      CoPlan.configuration.wake_url_policy = ->(_uri) { true }

      expect(described_class.vetted_addresses(URI.parse("http://trusted.internal/wake"))).to eq(:unpinned)
    end
  end
end
