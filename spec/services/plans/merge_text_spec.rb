require "rails_helper"

RSpec.describe CoPlan::Plans::MergeText do
  it "combines disjoint changes in one paragraph, including Unicode" do
    expect(described_class.call(base: "Café ☀️, alpha and beta.", local: "Café ☀️, ALPHA and beta.", remote: "Café ☀️, alpha and BETA.")).to eq("Café ☀️, ALPHA and BETA.")
  end

  it "preserves repeated text and multiple edits" do
    expect(described_class.call(base: "one two one three one", local: "ONE two one three ONE", remote: "one two ONE three one")).to eq("ONE two ONE three ONE")
  end

  it "deduplicates identical changes and accepts no-ops" do
    expect(described_class.call(base: "abc", local: "aBc", remote: "aBc")).to eq("aBc")
    expect(described_class.call(base: "abc", local: "abc", remote: "ab")).to eq("ab")
  end

  it "combines adjacent replacements and boundary insertions" do
    expect(described_class.call(base: "abc", local: "aBc", remote: "abC")).to eq("aBC")
    expect(described_class.call(base: "abc", local: "aXbc", remote: "aBc")).to eq("aXBc")
  end

  [ [ "abc", "aBc", "aQc" ], [ "abc", "ac", "aBc" ], [ "abc", "aXbc", "aYbc" ], [ "abcd", "ad", "abXcd" ] ].each do |base, local, remote|
    it "rejects overlapping replacement, deletion or insertion #{local.inspect} / #{remote.inspect}" do
      expect { described_class.call(base: base, local: local, remote: remote) }.to raise_error(described_class::Conflict)
    end
  end
end
