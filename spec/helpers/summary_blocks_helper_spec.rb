require "rails_helper"

RSpec.describe CoPlan::SummaryBlocksHelper, type: :helper do
  before { helper.extend(CoPlan::SlideshowsHelper) }

  def render(source, **options)
    Nokogiri::HTML::DocumentFragment.parse(helper.render_content_regions(source, **options))
  end

  let(:source) do
    <<~MD
      # Plan

      ::: {.summary}
      - **Ship** the queue option.[^why]
      - See [the dashboard](https://example.com/d).
      :::

      ## 1 Details

      Body text.

      [^why]: Measured on staging.
    MD
  end

  [ true, false ].each do |interactive|
    it "wraps the block in a summary card and drops its markers (interactive: #{interactive})" do
      doc = render(source, interactive:)
      card = doc.at_css("section.plan-summary")

      expect(card["id"]).to eq("plan-summary")
      expect(card["aria-label"]).to eq("Summary")
      expect(card.css("li").map { |item| item.text.squish }).to eq([ "Ship the queue option.1", "See the dashboard." ])
      expect(card.at_css("strong").text).to eq("Ship")
      expect(doc.text).not_to include(":::", "{.summary}")
      expect(doc.css("hr")).to be_empty
      expect(doc.at_css("h1").next_element).to eq(card)
      expect(card.next_element.name).to eq("h2")
      expect(doc.at_css("h2")["id"]).to eq("section-1")
      expect(doc.css("[data-sourcepos]")).to be_empty
    end
  end

  it "keeps a footnote citation inside the card linked to its definition" do
    citation = render(source).at_css("section.plan-summary sup.footnote-ref a")

    expect(citation["href"]).to eq("#fn-why")
    expect(citation.classes).to include("reference-anchor--footnote")
    footnotes = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(source, footnotes: :only))
    expect(footnotes.at_css("#fn-why").text).to include("Measured on staging.")
  end

  it "renders a second block as plain content" do
    doc = render("::: {.summary}\nFirst\n:::\n\n::: {.summary}\nSecond\n:::")

    expect(doc.css("section.plan-summary").size).to eq(1)
    expect(doc.at_css("section.plan-summary").text).to include("First")
    expect(doc.at_css("section.plan-summary").text).not_to include("Second")
    expect(doc.text).to include("::: {.summary}", "Second", ":::")
  end

  it "does not treat author HTML as the summary card" do
    doc = render(%(<section class="plan-summary note" id="plan-summary">Forged</section>\n\nBody))

    expect(doc.css(".plan-summary, #plan-summary")).to be_empty
    expect(doc.at_css("section.note").text).to eq("Forged")
  end

  it "keeps the real card when the author also forges one" do
    doc = render(%(<section class="plan-summary">Forged</section>\n\n#{source}))

    expect(doc.css("section.plan-summary").size).to eq(1)
    expect(doc.at_css("section.plan-summary").text).not_to include("Forged")
  end

  it "leaves an unclosed marker and a marker in code as text" do
    doc = render("```markdown\n::: {.summary}\n- Example\n:::\n```\n\n::: {.summary}\nUnclosed")

    expect(doc.css("section.plan-summary")).to be_empty
    expect(doc.at_css("pre code").text).to include("::: {.summary}")
    expect(doc.at_css("p").text).to include("::: {.summary}")
  end

  it "renders the summary in a plan that also has a deck" do
    doc = render("::: {.summary}\n- Short version\n:::\n\n::: {.presentation}\n\n# Slide\n\n:::\n\nAfter")

    expect(doc.at_css("section.plan-summary").text.squish).to eq("Short version")
    expect(doc.css(".deck-region .deck-slide").size).to eq(1)
  end

  it "keeps table comment targets inside the card resolvable" do
    content = "::: {.summary}\n| Option | Cost |\n|---|---|\n| Queue | Low |\n:::\n\nAfter"
    doc = render(content)
    targets = doc.css("section.plan-summary [data-source-target]").map { |node| JSON.parse(node["data-source-target"]) }

    expect(targets.size).to eq(4)
    targets.each do |target|
      resolved = CoPlan::Plans::SourceTargets.resolve(target["token"], content)
      expect(content[resolved["start"]...resolved["end"]].strip).to eq(target["text"].strip)
      expect(CoPlan::Plans::SourceTargets.new(content).ranges).to include(resolved.values_at("kind", "start", "end"))
    end
  end

  it "does not render a card outside a plan document" do
    doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown("::: {.summary}\nComment text\n:::"))

    expect(doc.css("section.plan-summary")).to be_empty
  end
end
