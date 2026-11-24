require "rails_helper"

RSpec.describe Coplan::Plans::MergeText do
  it "combines disjoint changes in one paragraph, including Unicode" do
    expect(described_class.call(base: "Café ☀️, alpha and beta.", local: "Café ☀️, ALPHA and beta.", remote: "Café ☀️, alpha and BETA.")).to eq("Café ☀️, ALPHA and BETA.")
  end

  it "preserves repeated text and multiple edits" do
    expect(described_class.call(base: "one two one three one", local: "ONE two one three ONE", remote: "one two ONE three one")).to eq("ONE two ONE three ONE")
  end

  describe "large character merges" do
    let(:prefix) { "# Report\n\n" }
    let(:middle) { (1..100).map { |i| "Unchanged line #{i}.\n" }.join }

    it "preserves a concurrent blank-line deletion between distant edits" do
      base = prefix + "bc\n\n\n\nc\n" + middle + "c\nb"
      local = prefix + "bcX\n\n\n\nc\n" + middle + "ac\nb"
      remote = prefix + "bc\n\n\nc\n" + middle + "c\nb"

      expect(described_class.call(base: base, local: local, remote: remote)).to eq(
        prefix + "bcX\n\n\nc\n" + middle + "ac\nb"
      )
    end

    it "keeps concurrent edits on the intended copy of a repeated line" do
      base = prefix + "repeat\nrepeat\nrepeat\n" + middle + "c\nb"
      local = prefix + "Xrepeat\nrepeat\nrepeat\n" + middle + "ac\nb"
      remote = prefix + "repeat?\nrepeat\nrepeat\n" + middle + "c\nb"

      expect(described_class.call(base: base, local: local, remote: remote)).to eq(
        prefix + "Xrepeat?\nrepeat\nrepeat\n" + middle + "ac\nb"
      )
    end

    it "combines disjoint edits separated by thousands of identical lines" do
      base = prefix + "begin\n" + ("\n" * 1_100) + "exact quote for review\n" + ("\n" * 1_100) + "end\n"
      local = base.sub("begin", "begin?").sub("end", "end!")
      remote = base.sub("for review", "for compliance review")

      expect(described_class.call(base: base, local: local, remote: remote)).to eq(local.sub("for review", "for compliance review"))
    end

    it "rejects an overlapping remote edit when the search falls back" do
      stub_const("Coplan::Plans::TextDiff::MAX_CHARACTER_CELLS", 0)
      stub_const("Coplan::Plans::TextDiff::MAX_SEARCH_STEPS", 1)
      base = "start\n" + ("unchanged\n" * 100) + "end\n"
      local = base.sub("start", "start!").sub("end", "end!")
      remote = base.dup.insert(400, "remote")

      expect { described_class.call(base: base, local: local, remote: remote) }.to raise_error(described_class::Conflict)
      expect(local).not_to include("remote")
      expect(remote).to include("remote")
    end
  end

  it "deduplicates identical changes and accepts no-ops" do
    expect(described_class.call(base: "abc", local: "aBc", remote: "aBc")).to eq("aBc")
    expect(described_class.call(base: "abc", local: "abc", remote: "ab")).to eq("ab")
  end

  it "combines edits separated by unchanged text" do
    expect(described_class.call(base: "abcd", local: "aBcd", remote: "abcD")).to eq("aBcD")
    expect(described_class.call(base: "abc", local: "Xabc", remote: "abcY")).to eq("XabcY")
  end

  [
    [ "abc", "aBc", "aQc" ], [ "abc", "ac", "aBc" ], [ "abc", "aXbc", "aYbc" ], [ "abcd", "ad", "abXcd" ],
    # Edits that touch: neither author wrote the spliced result.
    [ "Run the backfill daily.", "Run the backfill twice daily.", "Run the backfill weekly." ],
    [ "Ship in Q4.", "Ship in Q4 2027.", "Ship in Q3." ],
    [ "abc", "aBc", "abC" ], [ "abc", "aXbc", "aBc" ], [ "abc", "ac", "abXc" ]
  ].each do |base, local, remote|
    it "rejects overlapping or touching edits #{local.inspect} / #{remote.inspect}" do
      expect { described_class.call(base: base, local: local, remote: remote) }.to raise_error(described_class::Conflict)
      expect { described_class.call(base: base, local: remote, remote: local) }.to raise_error(described_class::Conflict)
    end
  end
end
