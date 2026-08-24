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

    it "stamps each slide with its classified pattern and type step" do
      doc = deck("# Opener\n\nA subtitle\n\n---\n\n## Points\n\n- one\n- two")

      title, content = doc.css("section.deck-slide")
      expect(title.classes).to include("deck-slide--title", "deck-step-1")
      expect(title["data-pattern"]).to eq("title")
      expect(content.classes).to include("deck-slide--content", "deck-step-1")
    end

    it "names the deck content container and the theme on the deck root" do
      doc = deck("# One")

      expect(doc.at_css(".deck")["data-deck-theme"]).to eq("coplan")
      expect(doc.at_css("section.deck-slide > .deck-content.markdown-rendered")).to be_present
    end

    it "wraps a trailing split image into panes with the heading spanning" do
      doc = deck("## Status\n\n- beta live\n- survey drafted\n\n![board](board.png)")

      slide = doc.at_css("section.deck-slide--split")
      expect(slide["data-media"]).to eq("trailing")
      children = slide.at_css(".deck-content").element_children
      expect(children.map(&:name)).to eq(%w[h2 div div])
      expect(children[1]["class"]).to eq("deck-body")
      expect(children[1].at_css("ul")).to be_present
      expect(children[2]["class"]).to eq("deck-media")
      expect(children[2].at_css("img")["src"]).to eq("board.png")
    end

    it "wraps a leading split image with the pane first in source order" do
      # Two text blocks so the image can't read as a stage caption's media.
      doc = deck("![board](board.png)\n\nThe words beside the picture.\n\nMore words below them.")

      children = doc.at_css("section.deck-slide--split .deck-content").element_children
      expect(children.map { |el| el["class"] }).to eq(%w[deck-media deck-body])
      expect(children.last.css("p").size).to eq(2)
    end

    it "skips split wrappers when sanitize deletes the classified shape" do
      # The classifier sees [image, html_block] — split, media leading. The
      # sanitizer then deletes the script wholesale, leaving one child; the
      # renderer must not wrap the wrong element (per SLIDE_SPEC.md).
      doc = deck("![art](a.png)\n\n<script>alert(1)</script>")

      slide = doc.at_css("section.deck-slide--split")
      expect(slide).to be_present
      expect(slide.css(".deck-media, .deck-body")).to be_empty
    end

    it "skips split wrappers rather than reorder loose text sanitize left behind" do
      # Sanitize reduces the <figure> block to a bare text node between two
      # body blocks. Wrapping only the elements would move them past the
      # text — a source-order violation — so the slide keeps flat markup.
      doc = deck("## Latency\n\n- p99 alert added\n\n<figure><figcaption>Figure 3: p99 by region</figcaption></figure>\n\nNotes live in the appendix.\n\n![chart](p99.png)")

      slide = doc.at_css("section.deck-slide--split")
      expect(slide.css(".deck-media, .deck-body")).to be_empty
      expect(slide.text.squish).to include("p99 alert added Figure 3: p99 by region Notes live in the appendix.")
    end

    it "keeps a raw-HTML heading inside the body pane instead of spanning it" do
      # The classifier saw [html_block, paragraph, image]: no lead heading,
      # so the rendered <h2> is body content — it must not take the
      # spanning direct-child slot a markdown lead heading gets.
      doc = deck("<h2>Pasted heading</h2>\n\nReal body prose, long enough that this cannot read as a caption riding along with the image on a stage slide under any of the catalog rules.\n\n![board](board.png)")

      content = doc.at_css("section.deck-slide--split .deck-content")
      expect(content.element_children.map { |el| el["class"] }).to eq(%w[deck-body deck-media])
      expect(content.at_css(".deck-body h2").text).to eq("Pasted heading")
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

    it "suffixes repeated heading anchors the way document mode does" do
      content = "# Intro\n\none\n\n---\n\n# Intro\n\ntwo"
      doc = deck(content)

      anchors = doc.css("a.anchor").map { |a| [ a["id"], a["href"] ] }
      expect(anchors).to eq([ [ "intro", "#intro" ], [ "intro-1", "#intro-1" ] ])
    end

    it "suffixes repeated heading anchors across a slide holding its own repeat" do
      content = "# Intro\n\n# Intro\n\n---\n\n# Intro"
      doc = deck(content)

      expect(doc.css("a.anchor").map { |a| a["id"] }).to eq(%w[intro intro-1 intro-2])
    end

    it "gives repeated numbered headings their document-mode section ids" do
      content = "# 1. Goals\n\ngoals\n\n---\n\n# 1. Goals\n\nrevisited, see [above](#section-1)"
      doc = deck(content)

      expect(doc.css("h1").map { |h| h["id"] }).to eq(%w[section-1 section-1-2])
    end

    it "keeps slide heading ids stable when a footnote definition holds a heading" do
      # The definition's heading renders only in the References back matter,
      # so it must not shift the ids of headings the slides actually show.
      content = "Ref[^a]\n\n[^a]: note\n\n    # Intro\n\n---\n\n# Intro\n\nslide two"
      doc = deck(content)

      expect(doc.css("a.anchor").map { |a| a["id"] }).to eq(%w[intro])
    end

    it "enhances section links whose target heading lives on another slide" do
      content = "See [goals](#section-2)\n\n---\n\n# 2. Goals\n\nthe goals"
      doc = deck(content)

      link = doc.at_css('a[href="#section-2"]')
      expect(link["class"]).to include("reference-anchor--section")
      expect(doc.at_css("#section-2")).to be_present
    end

    it "skips id alignment instead of swapping ids when raw HTML reorders content between renders" do
      # An unclosed <table> spanning the break foster-parents its heading
      # differently in document mode than in the isolated slide renders;
      # misassigning another heading's id would be worse than keeping
      # per-slide ids.
      content = "<table><tr><td>\n\n# 1. Alpha\n\n</td></tr>\n\n---\n\n# 2. Xray\n\n</table>\n\n# 3. Beta"
      doc = deck(content)

      expect(doc.at_css("#section-1").text).to include("Alpha")
      expect(doc.at_css("#section-2").text).to include("Xray")
    end

    it "keeps deck ids unique when an author footnote-section fake spans a slide break" do
      content = "## Intro\n\n<section data-footnotes>\n\n---\n\n## Intro\n\n</section>"
      doc = deck(content)

      ids = doc.css("[id]").map { |el| el["id"] }
      expect(ids).to eq(ids.uniq)
    end

    it "keeps real refs on their backref ids when an author anchor impersonates a footnote ref" do
      # comrak never emits class="anchor" together with data-footnote-ref;
      # the contradiction marks author HTML, which must neither shift real
      # references off their back-matter backrefs nor get renumbered itself.
      content = "First[^a] and <a class=\"anchor\" data-footnote-ref href=\"#fn-a\" id=\"fnref-a\">fake</a>\n\n---\n\nSecond[^a]\n\n[^a]: the definition"
      doc = deck(content)

      real = doc.css("a[data-footnote-ref]").reject { |a| a.text == "fake" }
      expect(real.map { |a| a["id"] }).to eq(%w[fnref-a fnref-a-2])
      expect(doc.css("a[data-footnote-ref]").map(&:text)).to include("fake")
      ids = doc.css("[id]").map { |el| el["id"] }
      expect(ids).to eq(ids.uniq)
    end

    it "strips a per-slide section enhancement document mode does not give" do
      # Slide 2's isolated render thinks its heading owns #section-1, but in
      # the document an author element claimed it first — the link is plain
      # in document mode.
      content = "<div id=\"section-1\">decoy</div>\n\n---\n\n# 1. Real\n\n[jump](#section-1)"
      doc = deck(content)

      link = doc.css('a[href="#section-1"]').find { |a| a.text == "jump" }
      expect(link["class"]).to be_nil
      expect(link["data-action"]).to be_nil
      expect(link["aria-haspopup"]).to be_nil
    end

    it "strips the stale enhancement when a per-slide section id lost to an earlier claimant" do
      # "Section 1" slugs its comrak anchor to section-1, so the numbered
      # heading is section-1-2 document-wide and #section-1 is not a section
      # target there.
      content = "## Section 1\n\nx\n\n---\n\n## 1. Numbered\n\n[num](#section-1)"
      doc = deck(content)

      link = doc.css('a[href="#section-1"]').find { |a| a.text == "num" }
      expect(link["class"]).to be_nil
      expect(doc.at_css("#section-1-2")).to be_present
    end

    it "enhances an author-classed cross-slide section link the way document mode does" do
      content = "# 1. Intro\n\nHello\n\n---\n\nGo <a href=\"#section-1\" class=\"reference-anchor--section\">jump</a> now"
      doc = deck(content)

      link = doc.css('a[href="#section-1"]').find { |a| a.text == "jump" }
      expect(link["aria-haspopup"]).to eq("dialog")
      expect(link["data-action"]).to include("reference-preview")
    end

    it "drops a surviving per-slide id whose document-mode owner shows different content" do
      # An author footnote-section fake spanning the break forces the
      # alignment skip; slide 2's isolated numbering then mints section-1-2
      # for Gamma while document mode's section-1-2 is Beta. A link written
      # against the document must never land on different content.
      content = "# 1. Alpha\n\n<section data-footnotes>\n\n---\n\n# 1. Beta\n\n# 1. Gamma\n\n</section>"
      doc = deck(content)

      expect(doc.at_css("#section-1").text).to include("Alpha")
      expect(doc.at_css("#section-1-2")).to be_nil
    end

    it "validates heading anchors by the heading they mark" do
      # Anchors are empty elements, so a stale per-slide anchor id can only
      # be caught by comparing its parent heading against the document-mode
      # owner's.
      content = "# Foo Bar\n\n<section data-footnotes>\n\n---\n\n# Foo-Bar\n\n# Foo Bar\n\n</section>"
      doc = deck(content)

      # Document mode's #foo-bar-1 marks "Foo-Bar"; the deck's surviving
      # anchors must not offer that id on a "Foo Bar" heading.
      expect(doc.at_css("#foo-bar-1")).to be_nil
      expect(doc.at_css("#foo-bar").parent.text.squish).to eq("Foo Bar")
    end

    it "does not swap ids between same-text headings whose link destinations differ" do
      # data-footnote-ref on an author link must not hide its href from the
      # alignment gate — genuine refs keep identical #fn-… hrefs in both
      # renders, so only impostors can differ here.
      content = "<table><tr><td>\n\n# 1. <a data-footnote-ref href=\"https://one.example\">go</a>\n\n</td></tr>\n\n---\n\n# 1. <a data-footnote-ref href=\"https://two.example\">go</a>\n\n</table>\n\n# 2. Beta"
      doc = deck(content)

      expect(doc.at_css("#section-1").at_css("a[data-footnote-ref]")["href"]).to eq("https://one.example")
    end

    it "does not swap ids between same-text headings whose images differ" do
      content = "<table><tr><td>\n\n# 1. ![chart A](https://img.example/a.png)\n\n</td></tr>\n\n---\n\n# 1. ![chart B](https://img.example/b.png)\n\n</table>\n\n# 2. Beta"
      doc = deck(content)

      expect(doc.at_css("#section-1").at_css("img")["src"]).to eq("https://img.example/a.png")
    end

    it "matches document mode when an author id claims a heading's number under an alignment skip" do
      content = "# 1. Real\n\n<table><tr><td>\n\n# 2. Alpha\n\n</td></tr>\n\n---\n\n# 3. Xray\n\n</table>\n\n<div id=\"section-1\">decoy</div>"
      doc = deck(content)

      expect(doc.at_css("#section-1").text).to eq("decoy")
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
