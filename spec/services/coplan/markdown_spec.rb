require "rails_helper"

RSpec.describe CoPlan::Markdown do
  def html(source)
    Nokogiri::HTML.fragment(described_class.to_html(source))
  end

  it "renders uppercase, lowercase, and numbered lists as separate adjacent lists" do
    doc = html("A) First\nB) Second\n\na) Lower\nb) Next\n\n1) Number\n2) Next number\n")
    expect(doc.css("ol").map { |list| list["type"] }).to eq([ "A", "a", nil ])
    expect(doc.css("ol").map { |list| list.css("li").map { |item| item.text.strip } }).to eq([
      [ "First", "Second" ], [ "Lower", "Next" ], [ "Number", "Next number" ]
    ])
  end

  it "supports lettered starts beyond Z and keeps nested lists" do
    doc = html("Z) Last single letter\nAA) First double letter\n\n    a) Nested\n    b) Next\n")
    expect(doc.at_css("ol")["start"]).to eq("26")
    expect(doc.at_css("ol")["type"]).to eq("A")
    expect(doc.at_css('li ol[type="a"]')).to be_present
    expect(doc.css("[data-sourcepos]")).to be_empty
  end

  it "keeps fenced code, indented code, inline code, and HTML literal" do
    source = "A) Actual item\n\n```text\nB) Fenced literal\n```\n\n    C) Indented literal\n\n`D) Inline literal`\n\n<div>\nE) HTML literal\n</div>\n"
    normalized, = described_class.normalize(source)
    expect(normalized).to start_with("1) Actual item")
    expect(normalized).to include("B) Fenced literal", "    C) Indented literal", "`D) Inline literal`", "E) HTML literal")
    expect(html(source).css('ol[type="A"]').length).to eq(1)
  end

  it "preserves source offsets for multibyte text and multi-letter markers" do
    source = "Z) café 🌱\nAA) 同じ\n"
    normalized, = described_class.normalize(source)
    expect(normalized.bytesize).to eq(source.bytesize)
    expect(normalized.index("同じ")).to eq(source.index("同じ"))
    text, positions = CoPlan::Plans::MarkdownTextExtractor.call(source)
    text.chars.each_with_index do |character, index|
      expect(source[positions[index]]).to eq(character) if positions[index]
    end
    expect(text).to include("café 🌱", "同じ")
    expect(text).not_to include("Z)", "AA)")
  end

  it "keeps letter-like markers literal inside table cells" do
    source = "A) Name | State\n--- | ---\nB) Label | Ready\n"
    expect(described_class.normalize(source).first).to eq(source)
    doc = html(source)
    expect(doc.css("ol")).to be_empty
    expect(doc.at_css("th").text).to eq("A) Name")
    expect(doc.at_css("td").text).to eq("B) Label")
  end

  it "retains numbered starts when a document also has lettered lists" do
    doc = html("A) Letter\n\n0) Zero\n1) One\n\n9. Nine\n")
    expect(doc.css("ol").map { |list| list["start"] }).to eq([ nil, "0", "9" ])
  end

  it "keeps letter-like markers literal inside a nested pipe-less table" do
    source = "AA) Parent\n\n    A) Name | State\n    --- | ---\n    B) Label | Ready\n"
    normalized, = described_class.normalize(source)
    expect(normalized).to include("    A) Name | State", "    B) Label | Ready")
    doc = html(source)
    expect(doc.css('ol[type="A"] > li').length).to eq(1)
    expect(doc.at_css("th").text).to eq("A) Name")
    expect(doc.at_css("td").text).to eq("B) Label")
  end

  it "does not rewrite authored ordered lists with custom source positions" do
    source = "A) Lettered\n\n<ol class=\"authored\" start=\"9\" data-sourcepos=\"custom\"><li>Authored item</li></ol>\n"
    doc = Nokogiri::HTML.fragment(described_class.to_html(source, options: { render: { unsafe: true, sourcepos: true } }))
    expect(doc.at_css('ol[type="A"] li').text).to eq("Lettered")
    expect(doc.at_css("ol.authored")["start"]).to eq("9")
    expect(doc.at_css("ol.authored")["data-sourcepos"]).to eq("custom")
    expect(doc.at_css("ol.authored li").text).to eq("Authored item")
  end

  it "keeps nested table comment targets bound to their original source" do
    source = "AA) Item\n\n    | Name | State |\n    | --- | --- |\n    | 同 | Ready |\n"
    doc = Nokogiri::HTML.fragment(described_class.to_html(source, options: { render: { sourcepos: true } }))
    CoPlan::Plans::SourceTargets.new(source).annotate(doc)
    targets = doc.css("td[data-source-target]").map { |cell| JSON.parse(cell["data-source-target"]) }
    expect(targets.length).to eq(2)
    targets.each do |target|
      expect(source[target["start"]...target["end"]]).to eq(target["text"])
      expect(CoPlan::Plans::SourceTargets.resolve(target["token"], source)).to include("kind" => "table_cell")
    end
  end
end
