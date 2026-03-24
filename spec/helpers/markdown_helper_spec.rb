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
end
