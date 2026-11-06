require "rails_helper"

RSpec.describe CoPlan::MarkdownDocumentTitle do
  it "uses only an opening top-level heading and preserves formatted Markdown" do
    content = "# A **bold** `title` &amp; more\n\nBody"
    expect(described_class.normalize(content, fallback: "Old")).to eq(content)
    expect(described_class.extract(content)).to eq("A bold title & more")
  end

  it "prepends the fallback without consuming headings in code, quotes, or decks" do
    [ "Body\n\n# Later", "> # Quote", "```md\n# Code\n```", "::: {.presentation}\n\n# Slide\n\n:::" ].each do |content|
      expect(described_class.normalize(content, fallback: "Saved")).to eq("# Saved\n\n#{content}")
    end
  end

  it "repairs empty headings and escapes fallback Markdown" do
    expect(described_class.normalize("#\n\nBody", fallback: "A *literal* title")).to eq("# A \\*literal\\* title\n\nBody")
    expect(described_class.normalize("Body", fallback: nil)).to eq("# Untitled\n\nBody")
    expect(described_class.normalize("#\n\nBody", allow_empty: true)).to eq("#\n\nBody")
  end

  it "lets metadata win only during backfill and is idempotent" do
    content = described_class.normalize("# Stale\n\nBody", fallback: "Saved", override: true)
    expect(content).to eq("# Saved\n\nBody")
    expect(described_class.normalize(content, fallback: "Saved", override: true)).to eq(content)
    expect(described_class.normalize(content, fallback: "Other")).to eq(content)
  end
  it "canonicalizes Setext and leading blank lines without consuming the body" do
    expect(described_class.normalize("\n\nA *formatted* title\n====\n\nBody")).to eq("# A *formatted* title\n\nBody")
    expect(described_class.normalize("\n# Old\n\nBody", fallback: "Saved", override: true)).to eq("# Saved\n\nBody")
  end
end
