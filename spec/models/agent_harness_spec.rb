require "rails_helper"

RSpec.describe CoPlan::AgentHarness, type: :model do
  describe ".resolve" do
    it "canonicalizes known Amp and Claude harness identities" do
      expect(described_class.resolve(identifier: "Amp CLI", display_name: "Amp").key).to eq("amp")
      expect(described_class.resolve(identifier: "claude-code", display_name: "Claude").key).to eq("claude-code")
    end

    it "creates an editable entry for an unknown harness" do
      harness = described_class.resolve(identifier: "Acme Agent", display_name: "Acme")

      expect(harness).to have_attributes(key: "acme-agent", display_name: "Acme")
    end
  end

  it "uses a generic built-in icon for an unknown harness" do
    expect(build(:agent_harness).built_in_icon).to eq("coplan/agent-avatar.svg")
  end
end
