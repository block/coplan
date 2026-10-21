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

  it "combines each person and agent into one row across versions and models" do
    sources = [
      { "kind" => "human", "user_id" => "person", "user_name" => "Hampton", "characters" => 30 },
      { "kind" => "human", "user_id" => "person", "user_name" => "Hampton", "characters" => 10 },
      { "kind" => "ai", "agent_name" => "Claude", "harness" => "claude-code", "model" => "model-a", "characters" => 25 },
      { "kind" => "ai", "agent_name" => "Claude", "harness" => "claude-code", "model" => "model-b", "characters" => 15 },
      { "kind" => "unknown", "user_name" => "Hampton", "characters" => 20 }
    ]
    rows = helper.writing_provenance_rows(summary(human: 40, ai: 40, unknown: 20, contributors: sources))
    expect(rows.map { |row| row.values_at(:label, :characters) }).to eq([ [ "Hampton", 40 ], [ "Claude", 40 ], [ "Unknown", 20 ] ])
    expect(rows[1][:details]).to contain_exactly("model-a", "model-b")
  end

  it "uses known people for older summaries and generic labels only when identity is unavailable" do
    person = create(:coplan_user, name: "Hampton")
    sources = [ { "kind" => "human", "user_id" => person.id, "characters" => 5 },
      { "kind" => "ai", "characters" => 4 } ]
    rows = helper.writing_provenance_rows(summary(human: 5, ai: 4, unknown: 1, contributors: sources))
    expect(rows.map { |row| row[:label] }).to eq([ "Hampton", "AI written", "Unknown" ])
  end

  it "omits zero-value categories for entirely human or AI writing" do
    human = helper.writing_provenance_rows(summary(human: 100, ai: 0, unknown: 0))
    ai = helper.writing_provenance_rows(summary(human: 0, ai: 100, unknown: 0))

    expect(human.map { |row| row.values_at(:label, :characters) }).to eq([ [ "Human written", 100 ] ])
    expect(ai.map { |row| row.values_at(:label, :characters) }).to eq([ [ "AI written", 100 ] ])
  end

  it "keeps unknown writing visible even below one percent" do
    rows = helper.writing_provenance_rows(summary(human: 1000, ai: 0, unknown: 1))

    expect(rows.last.values_at(:label, :characters)).to eq([ "Unknown", 1 ])
    expect(helper.writing_provenance_percent(rows.last[:characters], 1001)).to eq("<1%")
  end
end
