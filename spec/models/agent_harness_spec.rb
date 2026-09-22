require "rails_helper"

RSpec.describe CoPlan::AgentHarness, type: :model do
  describe ".resolve" do
    it "canonicalizes known Amp and Claude harness identities" do
      expect(described_class.resolve(identifier: "Amp CLI")).to have_attributes(key: "amp", display_name: "Amp")
      expect(described_class.resolve(identifier: "claude-code")).to have_attributes(key: "claude-code", display_name: "Claude")
    end

    it "creates an editable entry for an unknown harness" do
      harness = described_class.resolve(identifier: "Acme Agent")

      expect(harness).to have_attributes(key: "acme-agent", display_name: "Acme Agent")
    end

    it "bounds values derived from token metadata to the database columns" do
      harness = described_class.resolve(identifier: "A" * 400)

      expect(harness.key.length).to eq(255)
      expect(harness.display_name.length).to eq(255)
    end
  end

  it "uses a generic built-in icon for an unknown harness" do
    expect(build(:agent_harness).built_in_icon).to eq("coplan/agent-avatar.svg")
  end
end
