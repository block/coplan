require "rails_helper"

RSpec.describe CoPlan::MarkdownHelper, type: :helper do
  describe "#render_markdown" do
    it "converts markdown to HTML" do
      html = helper.render_markdown("# Hello\n\n**bold** text")
      expect(html).to include("<h1>")
      expect(html).to include("<strong>bold</strong>")
      expect(html).to include("markdown-rendered")
    end

    it "sanitizes dangerous HTML" do
      html = helper.render_markdown('<script>alert("xss")</script>')
      expect(html).not_to match(/<script>/)
    end

    it "preserves an HTML image width with and without image expansion" do
      markdown = '<img src="/images/mockup.png" alt="Console mockup" width="320">'

      [ true, false ].each do |expandable_images|
        doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown, expandable_images:))

        expect(doc.at_css("img")["width"]).to eq("320")
      end
    end

    it "preserves image width while removing unsafe image attributes and URLs" do
      markdown = '<img src="javascript:alert(1)" alt="Console mockup" width="320" height="180" style="position:fixed" onerror="alert(1)">'
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown))
      image = doc.at_css("img")

      expect(image["width"]).to eq("320")
      expect(image["src"]).to be_nil
      expect(image["height"]).to be_nil
      expect(image["style"]).to be_nil
      expect(image["onerror"]).to be_nil
    end

    it "allows details/summary collapse elements" do
      html = helper.render_markdown('<details><summary>Click me</summary>Hidden content</details>')
      expect(html).to include("<details>")
      expect(html).to include("<summary>")
      expect(html).to include("Hidden content")
    end

    it "handles nil gracefully" do
      html = helper.render_markdown(nil)
      expect(html).to include("markdown-rendered")
    end

    it "marks rendered markdown for Mermaid enhancement" do
      html = helper.render_markdown("```mermaid\ngraph LR\n  A --> B\n```")

      expect(html).to include('data-controller="coplan--mermaid coplan--syntax-highlight"')
      expect(html).to include('<pre lang="mermaid"><code>')
      expect(html).to include("graph LR")
    end

    it "opens external links in a new tab while keeping fragment links local" do
      markdown = "[Source](https://example.com/evidence) and [§1](#section-1).\n\n## 1 Decision"
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown))
      external = doc.at_css('a[href="https://example.com/evidence"]')
      internal = doc.at_css('a[href="#section-1"]')

      expect(external["target"]).to eq("_blank")
      expect(external["rel"]).to eq("noopener noreferrer")
      expect(external["data-reference-type"]).to eq("link")
      expect(internal["target"]).to be_nil
      expect(internal["rel"]).to be_nil
    end
  end

  describe "footnotes" do
    let(:markdown) { "A bold claim.[^1]\n\n[^1]: The supporting detail." }

    it "renders footnote references as superscript links" do
      html = helper.render_markdown(markdown)
      expect(html).to include('<sup class="footnote-ref">')
      expect(html).to include('href="#fn-1"')
      expect(html).to include('data-footnote-ref')
      expect(html).to include('class="reference-anchor reference-anchor--footnote"')
      expect(html).to include("mouseenter-&gt;coplan--reference-preview#enter")
      expect(html).to include("click-&gt;coplan--reference-preview#follow")
      expect(html).not_to include("click-&gt;coplan--reference-preview#pin")
    end

    it "renders the footnote section with a backreference" do
      html = helper.render_markdown(markdown)
      expect(html).to match(/<section class="footnotes" data-footnotes(="")?>/)
      expect(html).to include('<h2 class="footnotes-title">References</h2>')
      expect(html).to include("The supporting detail.")
      expect(html).to include('data-footnote-backref')
      expect(html).to include('href="#fnref-1"')
    end

    it "can split footnotes from the document body for unified back matter" do
      body = helper.render_markdown(markdown, footnotes: :exclude)
      footnotes = helper.render_markdown(markdown, footnotes: :only)

      expect(body).to include("A bold claim.")
      expect(body).not_to include('data-footnotes')
      expect(footnotes).to include('data-footnotes')
      expect(footnotes).to include("The supporting detail.")
      expect(footnotes).not_to include("A bold claim.")
    end

    it "works in non-interactive mode" do
      html = helper.render_markdown(markdown, interactive: false)
      expect(html).to include('data-footnotes')
    end

    it "keeps footnote text in plain-text extraction without literal markers" do
      plain = helper.markdown_to_plain_text(markdown)
      expect(plain).to include("The supporting detail.")
      expect(plain).not_to include("[^1]")
    end

    it "does not treat unreferenced bracket-caret text as a footnote" do
      html = helper.render_markdown("Just [^brackets] with no definition.")
      expect(html).to include("[^brackets]")
      expect(html).not_to include("footnote-ref")
    end

    it "scopes footnote ids and hrefs with footnote_prefix" do
      html = helper.render_markdown(markdown, footnote_prefix: "comment-abc")
      expect(html).to include('id="comment-abc-fnref-1"')
      expect(html).to include('href="#comment-abc-fn-1"')
      expect(html).to include('id="comment-abc-fn-1"')
      expect(html).to include('href="#comment-abc-fnref-1"')
      expect(html).not_to match(/id="fn(ref)?-1"/)
    end

    it "leaves non-footnote ids and anchors alone when prefixing" do
      html = helper.render_markdown("# Heading\n\n[jump](#fnord) <span id=\"fnord\">x</span>\n\n" + markdown, footnote_prefix: "p")
      expect(html).to include('href="#fnord"')
      expect(html).to include('id="fnord"')
    end
  end

  describe "internal section references" do
    let(:markdown) do
      <<~MARKDOWN
        # Plan

        See [§3.1](#section-3-1), but do not reinterpret the external statute RKSV §2.

        ### 3.1 Rollout

        Start with a five-percent cohort.
      MARKDOWN
    end

    it "gives numbered headings stable section ids" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown))

      expect(doc.at_css("h3")["id"]).to eq("section-3-1")
    end

    it "enhances explicit links to numbered sections for previews" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown))
      anchor = doc.at_css('a[href="#section-3-1"]')

      expect(anchor["class"]).to include("reference-anchor--section")
      expect(anchor["aria-haspopup"]).to eq("dialog")
      expect(anchor["aria-expanded"]).to eq("false")
      expect(anchor["data-action"]).to include("coplan--reference-preview#enter")
      expect(anchor["data-action"]).to include("click->coplan--reference-preview#follow")
      expect(anchor["data-action"]).not_to include("click->coplan--reference-preview#pin")
    end

    it "leaves bare section signs as text because they can cite external documents" do
      html = helper.render_markdown(markdown)

      expect(html).to include("RKSV §2")
      expect(html).not_to include('href="#section-2"')
    end

    it "does not enhance a fragment link when its numbered section is missing" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown("See [§9](#section-9)."))
      anchor = doc.at_css('a[href="#section-9"]')

      expect(anchor["class"]).to be_nil
      expect(anchor["data-action"]).to be_nil
    end

    it "does not create duplicate section ids in prefixed comment fragments" do
      html = helper.render_markdown("## 3.1 A heading inside a comment", footnote_prefix: "comment-abc")

      expect(html).not_to include('id="section-3-1"')
    end
  end

  describe "hover definitions (abbr)" do
    it "preserves abbr elements with their title" do
      html = helper.render_markdown('The <abbr title="Optimistic Concurrency Control">OCC</abbr> check.')
      expect(html).to include('<abbr title="Optimistic Concurrency Control">OCC</abbr>')
    end

    it "strips event-handler attributes from abbr" do
      html = helper.render_markdown('<abbr title="ok" onmouseover="alert(1)">X</abbr>')
      expect(html).to include("<abbr")
      expect(html).not_to include("onmouseover")
    end
  end

  describe "collapsible sections" do
    it "preserves the open attribute on details" do
      html = helper.render_markdown("<details open><summary>Expanded</summary>\n\nBody text.\n\n</details>")
      expect(html).to match(/<details open(="")?>/)
    end

    it "renders markdown inside a details block separated by blank lines" do
      html = helper.render_markdown("<details>\n<summary>More</summary>\n\n- [ ] Task inside\n\n</details>")
      expect(html).to include('type="checkbox"')
      expect(html).to include('data-line-text="- [ ] Task inside"')
      expect(html).not_to include("disabled")
    end
  end

  describe "line_offset" do
    it "shifts checkbox data-line back to document coordinates" do
      # The fragment is lines 6-8 of some larger document.
      html = helper.render_markdown("intro\n\n- [ ] task", line_offset: 5)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)

      cb = doc.at_css('input[type="checkbox"]')
      expect(cb["data-line"]).to eq("8")
      expect(cb["data-line-text"]).to eq("- [ ] task")
    end

    it "defaults to unshifted lines" do
      html = helper.render_markdown("- [ ] task")
      expect(html).to include('data-line="1"')
    end
  end

  describe "@-mention rendering" do
    it "renders [@username](mention:username) as a styled chip" do
      html = helper.render_markdown("Hey [@hampton](mention:hampton), please look")
      expect(html).to include('<span class="mention" data-mention-username="hampton">@hampton</span>')
    end

    it "ignores mismatched [text](mention:other) links" do
      html = helper.render_markdown("[hello](mention:hampton) is plain text")
      expect(html).not_to include('class="mention"')
    end

    it "leaves casual @-text alone" do
      html = helper.render_markdown("just casually mentioning @hampton here")
      expect(html).not_to include('class="mention"')
      expect(html).to include("@hampton")
    end

    it "escapes the username to prevent injection" do
      html = helper.render_markdown("[@evil<script>](mention:evil<script>)")
      # The pattern shouldn't match (has < which isn't in [\w.-]), so it's plain.
      expect(html).not_to include('class="mention"')
    end

    it "does not render chips inside fenced code blocks" do
      html = helper.render_markdown("```\n[@hampton](mention:hampton)\n```")
      expect(html).not_to include('class="mention"')
      expect(html).to include("[@hampton](mention:hampton)")
    end

    it "does not render chips inside inline code" do
      html = helper.render_markdown("`[@hampton](mention:hampton)`")
      expect(html).not_to include('class="mention"')
    end
  end

  describe "data tables" do
    let(:markdown) do
      <<~MD
        | Phase | Owner |
        |---|---|
        | One | sam |
      MD
    end

    it "frames a table so a wide one scrolls instead of running off the page" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown))

      grid = doc.at_css("div.data-grid")
      expect(grid["data-controller"]).to eq("coplan--data-grid")
      frame = grid.at_css("div.data-grid__frame")
      expect(frame["data-coplan--data-grid-target"]).to eq("frame")
      expect(frame.element_children.map(&:name)).to eq([ "table" ])
    end

    it "adds no visible text, so comment anchors count what they counted before" do
      framed = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown)).text
      bare = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown, data_tables: false)).text

      expect(framed).to eq(bare)
    end

    it "frames every table in a document" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown("#{markdown}\n#{markdown}"))

      expect(doc.css("div.data-grid").size).to eq(2)
      expect(doc.css("table").all? { |table| table.parent.classes.include?("data-grid__frame") }).to be(true)
    end

    it "leaves a document without tables alone" do
      html = helper.render_markdown("Just a paragraph.")

      expect(html).not_to include("data-grid")
    end

    it "can be turned off, for decks that own their own tabular layout" do
      html = helper.render_markdown(markdown, data_tables: false)

      expect(html).not_to include("data-grid")
      expect(html).to include("<table>")
    end
  end

  describe "expandable images" do
    let(:markdown) { "Before ![Console mockup](/images/console.png) after." }

    it "wraps prose only when the paragraph starts with an image or image-only link" do
      source = "![Mockup](/images/a.png) Beside the picture.\n\nBelow the picture.\n\n[![Linked](/images/a.png)](https://example.com) Beside the link.\n\n#{markdown}"
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(source))
      expect(doc.css("p.image-paragraph").map(&:text)).to eq([ " Beside the picture.", " Beside the link." ])
      expect(doc.css("p:not(.image-paragraph)").map(&:text)).to include("Below the picture.", "Before  after.")
    end

    it "frames an image for the image expander" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown))

      frame = doc.at_css("span.image-frame")
      expect(frame["data-controller"]).to eq("coplan--image-expand")
      expect(frame["data-action"]).to eq("dblclick->coplan--image-expand#expandFromDoubleClick")
      image = frame.at_css("img")
      expect(image["data-coplan--image-expand-target"]).to eq("image")
      expect(image["data-action"]).to eq("load->coplan--image-expand#measure")
      expect(image["alt"]).to eq("Console mockup")
    end

    it "adds no visible text, so comment anchors count what they counted before" do
      framed = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown)).text
      bare = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown, expandable_images: false)).text

      expect(framed).to eq(bare)
    end

    it "keeps an image-only link inside the frame, so the expand button is not nested in the link" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown("[![Mockup](/images/a.png)](https://example.com/full)"))

      frame = doc.at_css("span.image-frame")
      expect(frame.element_children.map(&:name)).to eq([ "a" ])
      expect(frame.at_css("a > img")).to be_present
    end

    it "frames only the image when the link also has text" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown("[see ![icon](/images/i.png) here](https://example.com)"))

      expect(doc.at_css("a > span.image-frame > img")).to be_present
    end

    it "frames each image in a link that holds several" do
      doc = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown("[![One](/a.png)![Two](/b.png)](https://example.com)"))

      expect(doc.css("span.image-frame").size).to eq(2)
      expect(doc.css("span.image-frame > img").size).to eq(2)
    end

    it "is off wherever data tables are, so decks opt out of both" do
      html = helper.render_markdown(markdown, data_tables: false)

      expect(html).not_to include("image-frame")
      expect(html).to include("<img")
    end
  end

  describe "math" do
    def render(markdown, **options)
      Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown(markdown, **options))
    end

    def math(doc)
      doc.css("[data-math-style]").map { |node| [ node.name, node["data-math-style"], node.text ] }
    end

    it "renders $inline$ as an inline math element wired to the KaTeX controller" do
      doc = render("Energy $E = mc^2$ matters.")

      node = doc.at_css("span[data-math-style]")
      expect(math(doc)).to eq([ [ "span", "inline", "E = mc^2" ] ])
      expect(node["data-controller"]).to eq("coplan--math")
      expect(doc.at_css("p").text).to eq("Energy E = mc^2 matters.")
    end

    it "renders $$display$$ inline and as its own paragraph" do
      expect(math(render("Area $$\\pi r^2$$ here."))).to eq([ [ "span", "display", "\\pi r^2" ] ])
      expect(math(render("$$\n\\int_0^1 x\\,dx\n$$\n"))).to eq([ [ "span", "display", "\n\\int_0^1 x\\,dx\n" ] ])
    end

    it "renders $`inline`$ code math" do
      expect(math(render("Use $`a_1 * b_2`$ here."))).to eq([ [ "code", "inline", "a_1 * b_2" ] ])
    end

    it "renders a math fence as display math" do
      doc = render("```math\n\\sum_{k=1}^n k\n```\n")

      expect(math(doc)).to eq([ [ "pre", "display", "\\sum_{k=1}^n k\n" ] ])
      expect(doc.at_css("pre")["data-controller"]).to eq("coplan--math")
      expect(render("```math notes\nx\n```\n").css("[data-math-style]")).to be_empty
    end

    it "keeps TeX that looks like Markdown literal" do
      expect(math(render("Sum $a_1 + b_2 * c_3 *d*$ end."))).to eq([ [ "span", "inline", "a_1 + b_2 * c_3 *d*" ] ])
    end

    it "leaves currency dollars as text" do
      [ "Lunch costs $5 and coffee costs $10.", "It went from $5 to $10", "Budget: $1,000 - $2,000", "Price $5$10" ].each do |text|
        doc = render(text)

        expect(doc.css("[data-math-style]")).to be_empty, "#{text.inspect} became math"
        expect(doc.at_css("p").text).to eq(text)
      end
    end

    it "leaves an escaped dollar and spaced dollars as text" do
      expect(render("Not math: \\$x$ or $ y $.").css("[data-math-style]")).to be_empty
    end

    it "leaves code spans and code blocks containing dollars untouched" do
      doc = render("Run `echo $HOME $x$` now.\n\n```sh\nprice=$5 total=$x$\n```\n\n    indented $y$\n")

      expect(doc.css("[data-math-style]")).to be_empty
      expect(doc.css("code").map(&:text)).to eq([ "echo $HOME $x$", "price=$5 total=$x$\n", "indented $y$\n" ])
      expect(doc.css("[data-controller~='coplan--math']")).to be_empty
    end

    it "renders math inside lists, tables, and footnotes" do
      markdown = <<~MARKDOWN
        - Item $a^2$
          1. Nested $b^2$

        | Term | Value |
        | --- | --- |
        | Area | $\\pi r^2$ |

        Claim.[^proof]

        [^proof]: Because $c^2 = a^2 + b^2$.
      MARKDOWN
      doc = render(markdown, footnote_prefix: "math")

      expect(doc.css("li > span[data-math-style], li li span[data-math-style]").map(&:text)).to include("a^2", "b^2")
      expect(doc.at_css("td span[data-math-style]").text).to eq("\\pi r^2")
      expect(doc.at_css("section[data-footnotes] span[data-math-style]").text).to eq("c^2 = a^2 + b^2")
      expect(doc.css("[data-math-style]").map { |node| node["data-controller"] }.uniq).to eq([ "coplan--math" ])
    end

    it "renders math in footnote-only and non-interactive renders" do
      footnotes = Nokogiri::HTML::DocumentFragment.parse(helper.render_markdown("Claim.[^a]\n\n[^a]: See $x$.", footnotes: :only))

      expect(footnotes.at_css("[data-math-style]")["data-controller"]).to eq("coplan--math")
      expect(render("Static $y$.", interactive: false).at_css("[data-math-style]")["data-controller"]).to eq("coplan--math")
    end

    it "keeps the math attribute only on comrak's elements and values" do
      doc = render(<<~MARKDOWN)
        <div data-math-style="inline">div</div>
        <span data-math-style="evil" data-controller="coplan--mermaid" onclick="alert(1)">bad value</span>
        <a href="/x" data-math-style="inline">link</a>

        Real $z$.
      MARKDOWN

      expect(doc.css("[data-math-style]").map(&:text)).to eq([ "z" ])
      expect(doc.css(".markdown-rendered [data-controller]").map { |node| node["data-controller"] }).to eq([ "coplan--math" ])
      expect(doc.to_html).not_to include("onclick")
      expect(doc.at_css("span[data-math-style]").attributes.keys).to contain_exactly("data-math-style", "data-controller")
    end

    it "uses the same math grammar when extracting plain text" do
      expect(helper.markdown_to_plain_text("Energy $E = mc^2$ costs $5 and $10.")).to eq("Energy E = mc^2 costs $5 and $10.")
    end
  end
end
