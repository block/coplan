module CoPlan
  module MarkdownHelper
    ALLOWED_TAGS = %w[
      h1 h2 h3 h4 h5 h6
      p div span
      ul ol li
      table thead tbody tfoot tr th td
      pre code
      a img input label
      strong em b i u s del
      blockquote hr br
      dd dt dl
      sup sub
      details summary
    ].freeze

    ALLOWED_ATTRIBUTES = %w[id class href src alt title type checked disabled data-line-text data-action data-coplan--checkbox-target data-mention-username].freeze

    # Matches `[@username](mention:username)` where the bracket text and link
    # target encode the same username. Username allows letters, digits, dots,
    # dashes, and underscores. The pattern must round-trip exactly so that
    # casual `[foo](mention:bar)` typed by hand doesn't get rendered as a chip.
    MENTION_PATTERN = /\[@([\w.-]+)\]\(mention:\1\)/

    def render_markdown(content, interactive: true)
      transformed = transform_mentions(content.to_s)
      html = Commonmarker.to_html(transformed.encode("UTF-8"), options: { render: { unsafe: true } }, plugins: { syntax_highlighter: nil })
      sanitized = sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
      result = interactive ? make_checkboxes_interactive(sanitized, content) : sanitized
      tag.div(result.html_safe, class: "markdown-rendered")
    end

    def transform_mentions(content)
      content.gsub(MENTION_PATTERN) do
        username = ::Regexp.last_match(1)
        escaped = ERB::Util.html_escape(username)
        %(<span class="mention" data-mention-username="#{escaped}">@#{escaped}</span>)
      end
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

        # Wrap li contents in a <label> so the whole text is clickable
        label = Nokogiri::XML::Node.new("label", doc)
        li.children.each { |child| label.add_child(child) }
        li.add_child(label)

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
