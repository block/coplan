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

      expect(html).to include('data-controller="coplan--mermaid"')
      expect(html).to include('<pre lang="mermaid"><code>')
      expect(html).to include("graph LR")
    end
  end

  describe "footnotes" do
    let(:markdown) { "A bold claim.[^1]\n\n[^1]: The supporting detail." }

    it "renders footnote references as superscript links" do
      html = helper.render_markdown(markdown)
      expect(html).to include('<sup class="footnote-ref">')
      expect(html).to include('href="#fn-1"')
      expect(html).to include('data-footnote-ref')
    end

    it "renders the footnote section with a backreference" do
      html = helper.render_markdown(markdown)
      expect(html).to match(/<section class="footnotes" data-footnotes(="")?>/)
      expect(html).to include("The supporting detail.")
      expect(html).to include('data-footnote-backref')
      expect(html).to include('href="#fnref-1"')
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
end
