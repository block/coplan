module CoPlan
  module MarkdownHelper
    ALLOWED_TAGS = %w[
      h1 h2 h3 h4 h5 h6
      p div span
      ul ol li
      table thead tbody tfoot tr th td
      pre code
      a img
      strong em b i u s del
      blockquote hr br
      dd dt dl
      sup sub
      details summary
    ].freeze

    ALLOWED_ATTRIBUTES = %w[id class href src alt title].freeze

    def render_markdown(content)
      html = Commonmarker.to_html(content.to_s.encode("UTF-8"), options: { render: { unsafe: true } }, plugins: { syntax_highlighter: nil })
      sanitized = sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
      tag.div(sanitized, class: "markdown-rendered")
    end

    def markdown_to_plain_text(content)
      html = Commonmarker.to_html(content.to_s.encode("UTF-8"), plugins: { syntax_highlighter: nil })
      Nokogiri::HTML::DocumentFragment.parse(html).text.squish
    end

    def render_line_view(content)
      lines = content.to_s.split("\n", -1)
      line_divs = lines.each_with_index.map do |line, index|
        n = index + 1
        escaped = ERB::Util.html_escape(line)
        inner = escaped.blank? ? "&nbsp;".html_safe : escaped
        tag.div(inner, class: "line-view__line", id: "L#{n}", data: { line: n })
      end

      tag.div(safe_join(line_divs), class: "line-view", data: { controller: "line-selection" })
    end
  end
end
