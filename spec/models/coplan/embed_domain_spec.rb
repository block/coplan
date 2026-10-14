require "rails_helper"
RSpec.describe CoPlan::EmbedDomain do
  it "normalizes exact DNS hostnames and rejects URLs, wildcards, paths and IP addresses" do
    domain = described_class.create!(hostname: " EMBED.Example.COM ")
    expect(domain.hostname).to eq("embed.example.com")
    expect(domain.id).to be_present
    expect(described_class.new(hostname: "embed.example.com")).not_to be_valid
    [ "https://embed.example.com", "*.example.com", "example.com/path", "example.com:443", "127.0.0.1", "localhost", "" ].each do |host|
      expect(described_class.new(hostname: host)).not_to be_valid
    end
  end
end
