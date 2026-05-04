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
  end

  describe "#render_line_view" do
    it "creates numbered divs" do
      html = helper.render_line_view("line one\nline two\nline three")
      expect(html).to include('id="L1"')
      expect(html).to include('id="L2"')
      expect(html).to include('id="L3"')
      expect(html).to include('data-line="1"')
      expect(html).to include('data-line="3"')
      expect(html).to include("line-view")
    end

    it "handles empty lines" do
      html = helper.render_line_view("line one\n\nline three")
      expect(html).to include('id="L2"')
      expect(html).to include("&nbsp;")
    end

    it "escapes HTML in content" do
      html = helper.render_line_view('<script>alert("xss")</script>')
      expect(html).not_to match(/<script>/)
      expect(html).to include("&lt;script&gt;")
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
