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

    ALLOWED_ATTRIBUTES = %w[id class lang href src alt title type checked disabled data-line data-line-text data-action data-coplan--checkbox-target data-mention-username data-sourcepos].freeze

    # A source line the toggle endpoint will accept as a task item. Shared
    # between the renderer and PlansController#toggle_checkbox so a checkbox
    # is only wired up when the server would accept toggling its line —
    # constructs Commonmarker renders as checkboxes but the endpoint rejects
    # (ordered-list or blockquoted tasks) stay disabled.
    TASK_LINE_PATTERN = /\A\s*[*+-]\s+\[[ xX]\]\s/

    # Matches `[@username](mention:username)` where the bracket text and link
    # target encode the same username. Username allows letters, digits, dots,
    # dashes, and underscores. The pattern must round-trip exactly so that
    # casual `[foo](mention:bar)` typed by hand doesn't get rendered as a chip.
    MENTION_PATTERN = /\[@([\w.-]+)\]\(mention:\1\)/

    def render_markdown(content, interactive: true)
      render_options = { unsafe: true }
      # Sourcepos is only needed to wire checkboxes to their source lines;
      # make_checkboxes_interactive strips it from the final output.
      render_options[:sourcepos] = true if interactive
      html = Commonmarker.to_html(content.to_s.encode("UTF-8"), options: { render: render_options }, plugins: { syntax_highlighter: nil })
      with_chips = transform_mention_anchors(html)
      sanitized = sanitize(with_chips, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
      result = interactive ? make_checkboxes_interactive(sanitized, content) : sanitized
      tag.div(result.html_safe, class: "markdown-rendered", data: { controller: "coplan--mermaid" })
    end

    # Replaces `<a href="mention:username">@username</a>` produced by
    # Commonmarker with a styled `<span>` chip. Runs on the parsed HTML so
    # that mentions inside fenced code blocks or inline code stay as literal
    # text — Commonmarker doesn't emit `<a>` tags inside code, so they're
    # naturally skipped here.
    def transform_mention_anchors(html)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      doc.css('a[href^="mention:"]').each do |anchor|
        username = anchor["href"].sub(/\Amention:/, "")
        next unless username.match?(/\A[\w.-]+\z/)
        next unless anchor.content == "@#{username}"

        span = Nokogiri::XML::Node.new("span", doc)
        span["class"] = "mention"
        span["data-mention-username"] = username
        span.content = "@#{username}"
        anchor.replace(span)
      end
      doc.to_html
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

    # Wires rendered task checkboxes to their source lines via Commonmarker's
    # sourcepos metadata, so the parser that decides what renders as a
    # checkbox is also the authority on which line it came from. A checkbox
    # only becomes interactive when its own source line matches
    # TASK_LINE_PATTERN.
    def make_checkboxes_interactive(html, content)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      source_lines = content.to_s.each_line.map(&:rstrip)

      doc.css('input[type="checkbox"]').each do |cb|
        li = cb.ancestors("li").first
        line_number = sourcepos_start_line(li)
        next unless line_number

        line_text = source_lines[line_number - 1]
        next unless line_text&.match?(TASK_LINE_PATTERN)

        cb.remove_attribute("disabled")
        cb["data-action"] = "coplan--checkbox#toggle"
        cb["data-coplan--checkbox-target"] = "checkbox"
        cb["data-line-text"] = line_text
        cb["data-line"] = line_number.to_s

        li.add_class("task-list-item")

        # Wrap li contents in a <label> so the whole text is clickable
        label = Nokogiri::XML::Node.new("label", doc)
        li.children.each { |child| label.add_child(child) }
        li.add_child(label)

        ul = li.parent
        ul.add_class("task-list") if ul&.name == "ul"
      end

      doc.css("[data-sourcepos]").each { |el| el.remove_attribute("data-sourcepos") }
      doc.to_html
    end

    # Extracts the 1-based start line from an li's data-sourcepos
    # ("3:1-4:0" -> 3).
    def sourcepos_start_line(li)
      raw = li&.[]("data-sourcepos")
      return nil if raw.nil?

      line = raw.split(":").first.to_i
      line >= 1 ? line : nil
    end
  end
end
