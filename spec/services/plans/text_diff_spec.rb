require "rails_helper"

RSpec.describe CoPlan::Plans::TextDiff do
  def apply(before, hunks)
    hunks.reverse_each.with_object(before.dup) { |hunk, text| text[hunk[:from]...hunk[:to]] = hunk[:text] }
  end

  # Records the cost of every LCS run so a spec can prove none was quadratic
  # on the whole document.
  def lcs_cells
    cells = []
    allow(Diff::LCS).to receive(:sdiff).and_wrap_original do |original, left, right|
      cells << left.length * right.length
      original.call(left, right)
    end
    cells
  end

  it "reproduces the new text for edits at the edges, in the middle and across lines, including Unicode" do
    base = "# Café ☀️\n\nalpha beta\ngamma\n"
    [ "", "X# Café ☀️\n\nalpha beta\ngamma\n", "# Café ☀️\n\nalpha BETA\ngamma\nend\n", "# Cafe\n\ngamma\n", base * 3 ].each do |after|
      expect(apply(base, described_class.hunks(base, after))).to eq(after)
    end
  end

  it "keeps a one-word edit to one word" do
    expect(described_class.hunks("one two three\n", "one TWO three\n")).to eq([ { from: 4, to: 7, text: "TWO" } ])
  end

  it "diffs a long document with two distant edits without a whole-document character LCS" do
    paragraphs = Array.new(1_100) { |i| "Paragraph #{i} says something about the rollout.\n" }
    before = paragraphs.join
    after = before.sub("Paragraph 10 says", "Paragraph 10 now says").sub("Paragraph 990 says", "Paragraph 990 also says")
    expect(before.length).to be > 50_000
    cells = lcs_cells

    hunks = described_class.hunks(before, after)

    expect(apply(before, hunks)).to eq(after)
    expect(hunks.map { |hunk| hunk[:text].strip }).to eq([ "now", "also" ])
    expect(cells.select { |count| count > described_class::MAX_CHARACTER_CELLS }.size).to be <= 1 # the line diff
    expect(cells.max).to be < 2_000_000
  end

  it "keeps a rewrite too large for a character diff as one hunk" do
    stub_const("#{described_class}::MAX_CHARACTER_CELLS", 10)
    before = "keep\nold text here\nkeep too\n"
    after = "keep\nnew words there\nkeep too\n"

    expect(described_class.hunks(before, after)).to eq([ { from: 5, to: 14, text: "new words t" } ])
  end

  it "clears or fills a long document without any LCS" do
    document = "Paragraph about the rollout.\n" * 10_000
    cells = lcs_cells

    expect(described_class.hunks(document, "")).to eq([ { from: 0, to: document.length, text: "" } ])
    expect(described_class.hunks("", document)).to eq([ { from: 0, to: 0, text: document } ])
    expect(cells).to be_empty
  end

  it "replaces the whole changed middle when even a line diff would be slow" do
    before = "start\n" + ("\n" * 2_000) + "end\n"
    after = "start!\n" + ("\n" * 1_500) + ("x\n" * 500) + "end!\n"
    cells = lcs_cells

    hunks = described_class.hunks(before, after)

    expect(apply(before, hunks)).to eq(after)
    expect(hunks.size).to eq(1)
    expect(cells).to be_empty
  end

  it "reports changed lines as offset ranges on both sides" do
    expect(described_class.line_hunks("a\nb\nc\n", "a\nB\nc\nd\n")).to eq([ [ 2, 4, 2, 4 ], [ 6, 6, 6, 8 ] ])
  end
end
