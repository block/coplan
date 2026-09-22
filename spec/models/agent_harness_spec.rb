require "rails_helper"

RSpec.describe CoPlan::AgentHarness, type: :model do
  describe ".resolve" do
    it "canonicalizes standard harness identities" do
      expected_harnesses = {
        "Amp CLI" => [ "amp", "Amp" ],
        "Claude Code" => [ "claude-code", "Claude" ],
        "OpenAI Codex" => [ "codex", "Codex" ],
        "Cursor Agent" => [ "cursor", "Cursor" ],
        "Google Gemini CLI" => [ "gemini-cli", "Gemini CLI" ],
        "goose" => [ "goose", "Goose" ],
        "Open Code" => [ "opencode", "OpenCode" ]
      }

      expected_harnesses.each do |identifier, (key, display_name)|
        expect(described_class.resolve(identifier: identifier)).to have_attributes(key: key, display_name: display_name)
      end
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

  it "uses the configured icons for built-ins and the generic icon otherwise" do
    described_class::BUILT_INS.each do |key, attributes|
      expect(build(:agent_harness, key: key).built_in_icon).to eq(attributes.fetch(:icon))
    end
    expect(build(:agent_harness).built_in_icon).to eq("coplan/agent-avatar.svg")
  end
end
