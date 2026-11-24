require "rails_helper"

RSpec.describe Coplan::Plans::TextDiff do
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

  it "scans long Unicode edges without repeatedly indexing characters" do
    edge = "é🙂e\u0301" * 4_000
    [ [ "#{edge}x", "#{edge}y", edge.length ], [ "x#{edge}", "y#{edge}", 0 ] ].each do |before, after, offset|
      [ before, after ].each do |text|
        allow(text).to receive(:[]).and_call_original
        expect(text).not_to receive(:[]).with(kind_of(Integer))
      end

      expect(described_class.hunks(before, after)).to eq([ { from: offset, to: offset + 1, text: "y" } ])
    end
  end

  it "does not overlap common Unicode edges when inserting or removing text" do
    [ [ "é🙂é", "é🙂🙂é" ], [ "é🙂🙂é", "é🙂é" ], [ "", "🙂" ], [ "🙂", "" ] ].each do |before, after|
      expect(apply(before, described_class.hunks(before, after))).to eq(after)
    end
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
    expect(cells).to be_empty
  end

  it "keeps a rewrite too large for a character diff as one hunk" do
    stub_const("#{described_class}::MAX_CHARACTER_CELLS", 10)
    stub_const("#{described_class}::MAX_SEARCH_STEPS", 1)
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

  it "replaces the whole changed middle when the character search exhausts its budget" do
    before = "start\n" + ("x" * 3_000) + "\nend\n"
    after = "start!\n" + ("y" * 3_000) + "\nend!\n"
    cells = lcs_cells

    hunks = described_class.hunks(before, after)

    expect(apply(before, hunks)).to eq(after)
    expect(hunks.size).to eq(1)
    expect(cells).to be_empty
  end

  it "discards a partial search when comparisons exhaust the shared budget" do
    stub_const("#{described_class}::MAX_CHARACTER_CELLS", 0)
    stub_const("#{described_class}::MAX_SEARCH_STEPS", 45)
    before = "a" + ("z" * 40) + "b"
    after = "c" + ("z" * 40) + "d"

    expect(described_class.hunks(before, after)).to eq([ { from: 0, to: 42, text: after } ])
  end

  it "bounds comparisons and stored frontier states across an entire rewrite" do
    stub_const("#{described_class}::MAX_SEARCH_STEPS", 200)
    before, after = "a" * 100, "b" * 100
    old_points, new_points = before.codepoints, after.codepoints
    allow(before).to receive(:codepoints).and_return(old_points)
    allow(after).to receive(:codepoints).and_return(new_points)
    expect(old_points).to receive(:[]).at_most(200).times.and_call_original
    expect(new_points).to receive(:[]).at_most(200).times.and_call_original
    expect(described_class).not_to receive(:backtrack)

    expect(described_class.bounded_character_hunks(before, after, 0)).to be_nil
  end

  it "finds shortest character edits with valid offsets for every small Unicode pair" do
    stub_const("#{described_class}::MAX_CHARACTER_CELLS", 0)
    alphabet = [ "a", "🙂", "\n" ]
    texts = (0..3).flat_map { |length| alphabet.repeated_permutation(length).map(&:join) }
    texts.product(texts).each do |before, after|
      hunks = described_class.hunks(before, after)
      expect(apply(before, hunks)).to eq(after)
      expect(hunks.each_cons(2).all? { |left, right| left[:to] < right[:from] }).to be(true)
      cost = hunks.sum { |hunk| hunk[:to] - hunk[:from] + hunk[:text].length }
      lcs_length = Diff::LCS.lcs(before.chars, after.chars).length
      expect(cost).to eq(before.length + after.length - 2 * lcs_length)
    end
  end

  it "reports changed lines as offset ranges on both sides" do
    expect(described_class.line_hunks("a\nb\nc\n", "a\nB\nc\nd\n")).to eq([ [ 2, 4, 2, 4 ], [ 6, 6, 6, 8 ] ])
  end
end
