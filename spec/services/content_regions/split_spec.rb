require "rails_helper"

RSpec.describe CoPlan::ContentRegions::Split do
  it "finds multiple presentation regions and preserves absolute source lines" do
    source = "Intro\n\n::: {.presentation #first theme=\"graphite\"}\n\n# A\n\n:::\n\nBetween\n\n::: {.presentation}\n\n# B\n\n:::\n\nEnd"
    result = described_class.call(source)

    expect(result.regions.map(&:kind)).to eq(%i[document presentation document presentation document])
    expect(result.regions.map(&:start_line)).to eq([1, 4, 8, 12, 16])
    expect(result.regions[1].id).to eq("first")
    expect(result.regions[1].theme).to eq("graphite")
    expect(result.canonical_source.lines.count).to eq(source.lines.count)
    expect(result.canonical_source).not_to include("::: {.presentation")
  end

  it "does not treat code examples, blockquotes, or unclosed fences as regions" do
    source = "```text\n::: {.presentation}\n```\n\n> ::: {.presentation}\n\n::: {.presentation}\n\nUnclosed"
    result = described_class.call(source)

    expect(result.regions.map(&:kind)).to eq([:document])
    expect(result.canonical_source).to eq(source)
  end
end
