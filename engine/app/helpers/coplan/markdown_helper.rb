module CoPlan
  module MarkdownHelper
    ALLOWED_TAGS = %w[
      h1 h2 h3 h4 h5 h6
      p div span
      ul ol li
      table thead tbody tfoot tr th td
      pre code
      a img input
      strong em b i u s del
      blockquote hr br
      dd dt dl
      sup sub
      details summary
    ].freeze

    ALLOWED_ATTRIBUTES = %w[id class href src alt title type checked disabled data-line-text data-action data-coplan--checkbox-target].freeze

    def render_markdown(content)
      html = Commonmarker.to_html(content.to_s.encode("UTF-8"), options: { render: { unsafe: true } }, plugins: { syntax_highlighter: nil })
      sanitized = sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
      interactive = make_checkboxes_interactive(sanitized, content)
      tag.div(interactive.html_safe, class: "markdown-rendered")
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

    private

    def make_checkboxes_interactive(html, content)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      checkboxes = doc.css('input[type="checkbox"]')
      return html if checkboxes.empty?

      task_lines = extract_task_lines(content)

      checkboxes.each_with_index do |cb, i|
        line_text = task_lines[i]
        next unless line_text

        cb.remove_attribute("disabled")
        cb["data-action"] = "coplan--checkbox#toggle"
        cb["data-coplan--checkbox-target"] = "checkbox"
        cb["data-line-text"] = line_text

        li = cb.parent
        next unless li&.name == "li"
        li.add_class("task-list-item")
        li.add_class("task-list-item--checked") if cb["checked"]

        ul = li.parent
        ul.add_class("task-list") if ul&.name == "ul"
      end

      doc.to_html
    end

    def extract_task_lines(content)
      lines = []
      in_fence = false
      content.to_s.each_line do |line|
        stripped = line.rstrip
        if stripped.match?(/\A(`{3,}|~{3,})/)
          in_fence = !in_fence
          next
        end
        next if in_fence
        lines << stripped if stripped.match?(/^\s*[*+-]\s+\[[ xX]\]\s/)
      end
      lines
    end
  end
end
