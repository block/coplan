require "rails_helper"

RSpec.describe CoPlan::WritingProvenanceHelper, type: :helper do
  def summary(human:, ai:, unknown:, contributors: [])
    { "total" => human + ai + unknown, "counts" => { "human" => human, "ai" => ai, "unknown" => unknown }, "contributors" => contributors }
  end

  it "keeps entirely distinct from a rounded near-100-percent majority" do
    expect(helper.writing_provenance_label(summary(human: 0, ai: 1000, unknown: 1))).to eq("Mostly AI written")
    expect(helper.writing_provenance_label(summary(human: 0, ai: 1000, unknown: 0))).to eq("Entirely AI written")
    expect(helper.writing_provenance_percent(1000, 1001)).to eq("99%")
    expect(helper.writing_provenance_percent(1, 1001)).to eq("<1%")
  end

  it "uses a harness name only when that harness authored the majority of the document" do
    sources = [ { "kind" => "ai", "harness" => "codex", "harness_name" => "Codex", "characters" => 40 },
      { "kind" => "ai", "harness" => "claude-code", "harness_name" => "Claude", "characters" => 30 } ]
    expect(helper.writing_provenance_label(summary(human: 20, ai: 70, unknown: 10, contributors: sources))).to eq("Mostly AI written")
    sources.first["characters"] = 60
    expect(helper.writing_provenance_label(summary(human: 10, ai: 90, unknown: 0, contributors: sources))).to eq("Mostly Codex written")
  end

  it "labels human, mixed, and unknown documents without guessing" do
    expect(helper.writing_provenance_label(summary(human: 80, ai: 10, unknown: 10))).to eq("Mostly human written")
    expect(helper.writing_provenance_label(summary(human: 40, ai: 40, unknown: 20))).to eq("Mixed writing origins")
    expect(helper.writing_provenance_label(nil)).to eq("Writing origin unknown")
  end
end
