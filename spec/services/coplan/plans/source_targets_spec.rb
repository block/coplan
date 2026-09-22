require "rails_helper"

RSpec.describe CoPlan::Plans::SourceTargets do
  def mapped(content)
    html = Commonmarker.to_html(content, options: { render: { sourcepos: true } }, plugins: { syntax_highlighter: nil })
    described_class.new(content).annotate(Nokogiri::HTML.fragment(html))
  end

  def cells(content)
    mapped(content).css("[data-source-target]").map { |cell| JSON.parse(cell["data-source-target"]) }
  end

  def graph(source)
    content = "é before\n\n```mermaid\n#{source}\n```\n"
    pre = mapped(content).at_css("pre")
    [ content, JSON.parse(pre["data-source-targets"] || "null") ]
  end

  it "maps repeated Unicode and formatted cells to character offsets in their own source" do
    content = "🌱\n\n| Nom | Note |\n| --- | --- |\n| 同 | **same** |\n| 同 | **same** |\n"
    targets = cells(content)
    same = targets.select { |t| t["text"].include?("same") }
    expect(same.size).to eq(2)
    expect(same.map { |t| t["start"] }.uniq.size).to eq(2)
    targets.each do |target|
      expect(content[target["start"]...target["end"]]).to eq(target["text"])
      expect(described_class.resolve(target["token"], content)).to include("kind" => "table_cell", "start" => target["start"])
    end
  end

  it "fences empty cells, including adjacent empty cells, with real source delimiters" do
    content = "| A | B | C |\n|---|---|---|\n||| |\n"
    empty = cells(content).last(3)
    expect(empty.map { |t| t["text"] }).to eq([ "||", "||", "| |" ])
    expect(empty.map { |t| t["start"] }.uniq.size).to eq(3)
    empty.each do |target|
      expect {
        CoPlan::Plans::TransformRange.transform([ target["start"], target["end"] ],
          resolved_range: [ target["start"] + 1, target["start"] + 1 ], delta: 4)
      }.to raise_error(CoPlan::Plans::TransformRange::Conflict)
    end
  end

  it "maps escaped pipes without confusing the cell boundary" do
    targets = cells("| A | B |\n|---|---|\n| a\\|b | `x` |\n")
    expect(targets.last(2).map { |t| t["text"] }).to eq([ " a\\|b ", " `x` " ])
  end

  it "refuses synthetic cells with no source span" do
    targets = cells("| A | B |\n|---|---|\n| a |\n")
    expect(targets.size).to eq(3)
  end

  it "identifies repeated labels, parallel unlabeled edges, and chains independently" do
    content, map = graph("flowchart LR\n A[Same]-->B[Same]\n A-->B\n B -->|yes| C{同} --> D")
    expect(map["nodes"].keys).to eq(%w[A B C D])
    expect(map["edges"].size).to eq(4)
    expect(map["edges"].first(2).map { |t| t["start"] }.uniq.size).to eq(2)
    (map["nodes"].values + map["edges"]).each do |target|
      expect(content[target["start"]...target["end"]]).to eq(target["text"])
    end
    expect(map["nodes"]["C"]["text"]).to eq("C{同}")
    expect(map["edges"].last["text"]).to eq("C{同} --> D")
  end

  it "declines nodes with repeated declarations rather than choosing by label" do
    _, map = graph("graph TD\nA[One] --> B\nA[Two]")
    expect(map["nodes"].keys).to eq([ "B" ])
  end

  it "offers an exact whole-fence fallback for other diagram types without inventing element targets" do
    [ "sequenceDiagram\nA->>B: hello", "flowchart LR\nA & B --> C", "flowchart LR\nA@{\n shape: rect\n} --> B" ].each do |source|
      content, map = graph(source)
      expect(map.values_at("nodes", "edges")).to eq([ {}, [] ])
      target = map.fetch("diagram")
      expect(target["text"]).to eq("```mermaid\n#{source}\n```")
      expect(described_class.resolve(target["token"], content)).to include("kind" => "mermaid_diagram")
      expect(described_class.new(content).ranges).to include([ "mermaid_diagram", target["start"], target["end"] ])
    end
  end

  it "maps new single-line shape declarations and their connections" do
    _, map = graph('flowchart LR; A@{ shape: doc, label: "Same {label}" } --> B@{ shape: cyl, label: "Same {label}" }')
    expect(map["nodes"].keys).to eq(%w[A B])
    expect(map["nodes"]["A"]["text"]).to eq('A@{ shape: doc, label: "Same {label}" }')
    expect(map["edges"].size).to eq(1)
  end

  it "rejects a token after any source edit, or after tampering" do
    content = "| A | B |\n|---|---|\n| x | y |\n"
    token = cells(content).last["token"]
    expect(described_class.resolve(token, "prefix\n#{content}")).to be_nil
    expect(described_class.resolve(token + "x", content)).to be_nil
  end
end

RSpec.describe CoPlan::Plans::SourceTargets, "untrusted HTML" do
  it "never signs author-supplied source positions on raw HTML tables" do
    content = "Secret source\n\n<table><tr><td data-sourcepos=\"1:1-1:6\">Misleading label</td></tr></table>"
    html = Commonmarker.to_html(content, options: { render: { sourcepos: true, unsafe: true } })
    doc = described_class.new(content).annotate(Nokogiri::HTML.fragment(html))
    expect(doc.css("[data-source-target]")).to be_empty
  end
end
