require "rails_helper"

RSpec.describe CoPlan::SlideshowsHelper, type: :helper do
  def deck(content, **options)
    Nokogiri::HTML::DocumentFragment.parse(helper.render_slideshow(content, **options))
  end

  describe "#render_slideshow" do
    it "wraps each slide in a deck section with its 1-based index" do
      doc = deck("# One\n\n---\n\n# Two")

      sections = doc.css(".deck > section.deck-slide")
      expect(sections.map { |s| s["data-slide"] }).to eq(%w[1 2])
      expect(sections.first.css("h1").text.strip).to eq("One")
      expect(sections.last.css("h1").text.strip).to eq("Two")
    end

    it "renders slide content through the standard markdown pipeline" do
      doc = deck("# Slide\n\n**bold** and <script>alert(1)</script>")

      expect(doc.css(".deck-slide .markdown-rendered")).to be_present
      expect(doc.css("strong").text).to eq("bold")
      expect(doc.css("script")).to be_empty
    end

    it "keeps checkbox source lines document-absolute on later slides" do
      content = "# One\n\n- [ ] first task\n\n---\n\n# Two\n\n- [ ] second task"
      doc = deck(content)

      lines = doc.css('input[type="checkbox"]').map { |cb| cb["data-line"] }
      expect(lines).to eq(%w[3 9])
    end

    it "renders non-interactive checkboxes when interactive: false" do
      doc = deck("- [ ] task", interactive: false)

      cb = doc.at_css('input[type="checkbox"]')
      expect(cb["disabled"]).to be_present
      expect(cb["data-line"]).to be_nil
    end

    it "resolves link-reference definitions across slide boundaries" do
      content = "See [the docs][docs]\n\n---\n\nslide two\n\n[docs]: https://example.com"
      doc = deck(content)

      link = doc.at_css('.deck-slide[data-slide="1"] a[href="https://example.com"]')
      expect(link.text).to eq("the docs")
    end

    it "resolves footnote references on other slides than their definition" do
      content = "Claim[^src]\n\n---\n\nmore\n\n[^src]: the source"
      doc = deck(content)

      ref = doc.at_css('.deck-slide[data-slide="1"] a[data-footnote-ref]')
      expect(ref).to be_present
      expect(ref["href"]).to eq("#fn-src")
    end

    it "excludes footnote definition sections from every slide" do
      content = "Claim[^src]\n\n[^src]: lives in back matter\n\n---\n\nAnother[^src]"
      doc = deck(content)

      expect(doc.css("section[data-footnotes]")).to be_empty
      expect(doc.text).not_to include("lives in back matter")
    end

    it "numbers footnote marks document-wide, not per slide" do
      content = <<~MD
        First[^a] and second[^b]

        ---

        Third[^c] and first again[^a]

        [^a]: A
        [^b]: B
        [^c]: C
      MD
      doc = deck(content)

      marks = doc.css("a[data-footnote-ref]").map { |a| [ a["href"], a.text ] }
      expect(marks).to eq([ [ "#fn-a", "1" ], [ "#fn-b", "2" ], [ "#fn-c", "3" ], [ "#fn-a", "1" ] ])
    end

    it "renames repeat references to document-mode ids so backrefs resolve" do
      content = "First[^a]\n\n---\n\nAgain[^a]\n\n[^a]: A"
      doc = deck(content)

      ids = doc.css("[id]").map { |el| el["id"] }
      expect(ids).to eq(ids.uniq)
      # The back matter emits one ↩ backref per reference (#fnref-a,
      # #fnref-a-2, ...); every one must land on a slide.
      expect(doc.css("#fnref-a").size).to eq(1)
      expect(doc.css("#fnref-a-2").size).to eq(1)
    end

    it "matches back-matter numbering when a footnote is referenced only inside another definition" do
      content = "Main[^a]\n\n[^a]: see [^hidden]\n[^hidden]: secret\n\n---\n\nNext[^b]\n\n[^b]: b note"
      doc = deck(content)

      marks = doc.css("a[data-footnote-ref]").map(&:text)
      # The back matter lists fn-a, fn-hidden, fn-b — so [^b] is 3, not 2.
      expect(marks).to eq(%w[1 3])
    end

    it "leaves author-supplied decoy footnote anchors alone" do
      content = "Decoy <a href=\"#fn-zzz\" data-footnote-ref>9</a> here\n\nReal[^a]\n\n[^a]: note\n\n---\n\nSecond[^b]\n\n[^b]: another"
      doc = deck(content)

      marks = doc.css("a[data-footnote-ref]").map { |a| [ a["href"], a.text ] }
      expect(marks).to eq([ [ "#fn-zzz", "9" ], [ "#fn-a", "1" ], [ "#fn-b", "2" ] ])
    end

    it "never leaks shared definitions into visible text via an unclosed fence" do
      content = "Ref[^a]\n\n[^a]: the definition\n\n---\n\n# Last\n\n```\nunclosed code\n"
      doc = deck(content)

      expect(doc.text).not_to include("the definition")
    end

    it "resolves duplicate-key references the way document mode does (first definition wins)" do
      content = "[docs]: https://first.example\n\nSee [the docs][docs]\n\n---\n\n[docs]: https://second.example\n\nSee [the docs][docs] again"
      doc = deck(content)

      hrefs = doc.css("a[href*=example]").map { |a| a["href"] }.uniq
      expect(hrefs).to eq([ "https://first.example" ])
    end

    it "renders a slide holding an unreferenced footnote definition instead of blanking it" do
      content = "# One\n\ntext one\n\n---\n\n# Two\n\ntext two\n\n[^wip]: draft note not referenced yet"
      doc = deck(content)

      expect(doc.css(".deck-slide").last.text).to include("text two")
    end

    it "renders slides whose footnote labels are unicode fold-equal" do
      content = "S1[^straße]\n\n[^straße]: eszett\n\n---\n\nS2[^STRASSE]\n\n[^STRASSE]: caps"
      doc = deck(content)

      text = doc.css(".deck-slide").map(&:text).join
      expect(text).to include("S1")
      expect(text).to include("S2")
    end

    it "numbers marks by the back matter's visible list positions, decoys included" do
      # A raw <li> smuggled into a definition body gets hoisted to a direct
      # <ol> child by HTML parsing — browsers show it as a numbered item, so
      # the real footnote after it is visibly item 3 and the deck must say 3.
      content = "First[^x] and second[^a]\n\n[^x]: <li id=\"fn-zzz\">decoy</li>\n\n[^a]: real"
      doc = deck(content)

      expect(doc.css("a[data-footnote-ref]").map(&:text)).to eq(%w[1 3])
    end

    it "ignores decoy list items that stay nested inside a definition body" do
      content = "First[^x] and second[^a]\n\n[^x]: <ul><li id=\"fn-zzz\">decoy</li></ul>\n\n[^a]: real"
      doc = deck(content)

      expect(doc.css("a[data-footnote-ref]").map(&:text)).to eq(%w[1 2])
    end

    it "leaves decoy anchors targeting a real definition untouched" do
      content = %(Intro <a href="#fn-a" data-footnote-ref>boo</a> decoy.\n\nReal ref[^a]\n\n[^a]: definition)
      doc = deck(content)

      anchors = doc.css("a[data-footnote-ref]").map { |a| [ a.text, a["id"] ] }
      expect(anchors).to eq([ [ "boo", nil ], [ "1", "fnref-a" ] ])
    end

    it "keeps checkbox lines document-absolute when definitions are prepended" do
      content = "Intro[^a]\n\n[^a]: note\n\n---\n\n- [ ] task on line seven"
      doc = deck(content)

      expect(doc.at_css('input[type="checkbox"]')["data-line"]).to eq("7")
    end

    it "renders an empty deck for blank content" do
      doc = deck("")

      expect(doc.at_css(".deck")).to be_present
      expect(doc.css(".deck-slide")).to be_empty
    end
  end
end
