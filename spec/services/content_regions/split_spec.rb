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

  it "separates script regions from surrounding prose and preserves literal examples" do
    source = "~~~md\n::: {.component}\n\n:::\n~~~\n\n::: {.component #chart uses=\"a@1 b@2\" title=\"Chart\"}\n\nroot.textContent = 'hello';\n\n:::\n\nAfter"
    result = described_class.call(source)
    expect(result.regions.map(&:kind)).to eq(%i[document component document])
    component = result.regions.second
    expect(component.attributes).to eq({ "uses" => "a@1 b@2", "title" => "Chart" })
    expect(component.id).to eq("chart")
    expect(result.component_mask.index("After")).to eq(source.index("After"))
    expect(result.canonical_source).not_to include("root.textContent")
  end

  it "treats the body as JavaScript when Markdown-looking strings swallow the closing marker" do
    source = "::: {.component}\n\nroot.textContent = `\n~~~js\nhello\n`;\n\n:::\n\n::: {.component}\n\nroot.textContent = 'second';\n\n:::\n"
    expect(described_class.call(source).regions.map(&:kind)).to eq(%i[component component])
  end

  it "bounds Markdown parsing to the surrounding prose when many scripts contain fence-like text" do
    block = "::: {.component}\n\nroot.textContent = `\n~~~js\nhello\n`;\n\n:::\n\n"
    source = ("Example\n\n" + block) * 100
    parsed_bytes = 0
    allow(CoPlan::Markdown).to receive(:parse).and_wrap_original do |original, text, **options|
      parsed_bytes += text.bytesize
      original.call(text, **options)
    end

    expect(described_class.call(source).regions.count { |r| r.kind == :component }).to eq(100)
    expect(parsed_bytes).to be <= source.bytesize * 3
  end

  it "keeps a paired presentation region with no slide content" do
    source = "::: {.presentation}\n\n:::"
    result = described_class.call(source)

    expect(result.regions.map(&:kind)).to eq([ :presentation ])
    expect(result.regions.first.source).to eq("")
    expect(result.canonical_source).not_to include(":::")
  end
end
