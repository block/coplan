require "rails_helper"

RSpec.describe CoPlan::ContentRegions::Split do
  it "finds multiple presentation regions and preserves absolute source lines" do
    source = "Intro\n\n::: {.presentation #first theme=\"graphite\"}\n\n# A\n\n:::\n\nBetween\n\n::: {.presentation}\n\n# B\n\n:::\n\nEnd"
    result = described_class.call(source)

    expect(result.regions.map(&:kind)).to eq(%i[document presentation document presentation document])
    expect(result.regions.map(&:start_line)).to eq([ 1, 4, 8, 12, 16 ])
    expect(result.regions[1].id).to eq("first")
    expect(result.regions[1].theme).to eq("graphite")
    expect(result.canonical_source.lines.count).to eq(source.lines.count)
    expect(result.canonical_source).not_to include("::: {.presentation")
  end

  it "does not treat code examples, blockquotes, or unclosed fences as regions" do
    source = "```text\n::: {.presentation}\n```\n\n> ::: {.presentation}\n\n::: {.presentation}\n\nUnclosed"
    result = described_class.call(source)

    expect(result.regions.map(&:kind)).to eq([ :document ])
    expect(result.canonical_source).to eq(source)
  end

  it "keeps a paired presentation region with no slide content" do
    source = "::: {.presentation}\n\n:::"
    result = described_class.call(source)

    expect(result.regions.map(&:kind)).to eq([ :presentation ])
    expect(result.regions.first.source).to eq("")
    expect(result.canonical_source).not_to include(":::")
  end

  describe "summary blocks" do
    it "finds a summary whose closer follows a list without a blank line" do
      source = "# Title\n\n::: {.summary}\n- One\n- Two\n:::\n\nBody"
      result = described_class.call(source)

      expect(result.summary.to_h).to eq(open_line: 3, close_line: 6)
      expect(result.regions.map(&:kind)).to eq([ :document ])
      expect(result.canonical_source.lines.map(&:length)).to eq(source.lines.map(&:length))
      expect(result.canonical_source).not_to include("{.summary}", ":::")
    end

    it "keeps only the first block and ignores markers in code, quotes, and raw HTML" do
      source = "```text\n::: {.summary}\n:::\n```\n\n> ::: {.summary}\n\n<div>\n::: {.summary}\n</div>\n\n" \
        "::: {.summary}\nFirst\n:::\n\n::: {.summary}\nSecond\n:::"
      result = described_class.call(source)

      expect(result.summary.to_h).to eq(open_line: 12, close_line: 14)
      expect(result.canonical_source).to include("::: {.summary}\nSecond\n:::")
    end

    it "leaves an unclosed summary and one interrupted by a deck as text" do
      expect(described_class.call("::: {.summary}\n- One").summary).to be_nil

      result = described_class.call("::: {.summary}\n\n::: {.presentation}\n\n# Slide\n\n:::\n\nAfter")
      expect(result.summary).to be_nil
      expect(result.regions.map(&:kind)).to eq(%i[document presentation document])
    end

    it "extracts the block's reading text without citation markers" do
      source = "::: {.summary}\n- **Ship** it with [the flag](https://example.com).[^why]\n- `Two`\n:::\n\nBody text.\n\n[^why]: Because."

      expect(described_class.summary_text(source)).to eq("Ship it with the flag. Two")
      expect(described_class.summary_text("No summary here.")).to be_nil
      expect(described_class.summary_text("::: {.summary}\n:::")).to be_nil
    end
  end
end
