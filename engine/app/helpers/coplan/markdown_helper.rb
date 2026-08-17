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
      abbr
      section
    ].freeze

    ALLOWED_ATTRIBUTES = %w[id class lang href src alt title target rel type checked disabled open aria-label aria-haspopup aria-expanded data-line data-line-text data-action data-mention-username data-sourcepos data-reference-type data-footnotes data-footnote-ref data-footnote-backref data-footnote-backref-idx].freeze

    # Commonmarker extensions beyond the gem defaults (tables, tasklist,
    # strikethrough, autolink stay on). Footnotes: `[^1]` in text plus a
    # `[^1]: definition` block anywhere in the document.
    EXTENSION_OPTIONS = { footnotes: true }.freeze

    # A source line the toggle endpoint will accept as a task item. Shared
    # between the renderer and PlansController#toggle_checkbox so a checkbox
    # is only wired up when the server would accept toggling its line —
    # constructs Commonmarker renders as checkboxes but the endpoint rejects
    # (ordered-list or blockquoted tasks) stay disabled.
    TASK_LINE_PATTERN = /\A\s*[*+-]\s+\[[ xX]\]\s/

    # Fragment caches of rendered markdown are keyed on content SHA plus this
    # version. Bump it whenever the rendering pipeline changes output for the
    # same input (new tags, attribute changes, checkbox wiring, etc.), or
    # stale HTML will be served from cache.
    RENDER_CACHE_VERSION = 5

    # Matches `[@username](mention:username)` where the bracket text and link
    # target encode the same username. Username allows letters, digits, dots,
    # dashes, and underscores. The pattern must round-trip exactly so that
    # casual `[foo](mention:bar)` typed by hand doesn't get rendered as a chip.
    MENTION_PATTERN = /\[@([\w.-]+)\]\(mention:\1\)/

    # footnote_prefix: pass a DOM-unique string when a page renders more than
    # one markdown fragment (e.g. each comment) — commonmarker numbers
    # footnote ids from #fn-1 per document, so unprefixed fragments collide
    # and reference/backref links jump to the wrong footnote.
    def render_markdown(content, interactive: true, footnote_prefix: nil)
      render_options = { unsafe: true }
      # Sourcepos is only needed to wire checkboxes to their source lines;
      # make_checkboxes_interactive strips it from the final output.
      render_options[:sourcepos] = true if interactive
      html = Commonmarker.to_html(content.to_s.encode("UTF-8"), options: { extension: EXTENSION_OPTIONS, render: render_options }, plugins: { syntax_highlighter: nil })
      with_chips = transform_mention_anchors(html)
      with_references = transform_reference_anchors(with_chips, numbered_sections: footnote_prefix.nil?)
      sanitized = sanitize(with_references, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
      result = interactive ? make_checkboxes_interactive(sanitized, content) : sanitized
      result = scope_footnote_ids(result, footnote_prefix) if footnote_prefix
      tag.div(result.html_safe, class: "markdown-rendered", data: { controller: "coplan--mermaid coplan--syntax-highlight" })
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

    # Numbered headings get stable fragments so agents can write explicit,
    # unambiguous same-document references such as
    # `[§3.1](#section-3-1)`. Plain `§3.1` text is deliberately not linked:
    # research plans also cite external laws as `RKSV §3.1`, where guessing
    # that the target is a CoPlan heading would create incorrect links.
    #
    # Footnote citations and valid numbered-section links opt into the shared
    # reference-preview controller. It reads their already-rendered targets,
    # so previews require no duplicate citation data or network request.
    def transform_reference_anchors(html, numbered_sections: true)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      used_ids = doc.css("[id]").filter_map { |node| node["id"].presence }.to_set
      section_ids = Set.new

      doc.css("a[href]").each do |anchor|
        next unless anchor["href"].match?(%r{\Ahttps?://}i)

        anchor["target"] = "_blank"
        anchor["rel"] = "noopener noreferrer"
        anchor["data-reference-type"] = Reference.classify_url(anchor["href"])
      end

      if numbered_sections
        doc.css("h1, h2, h3, h4, h5, h6").each do |heading|
          section_number = heading.text.squish[/\A(\d+(?:\.\d+)*)\b/, 1]
          next unless section_number

          heading["id"] ||= unique_dom_id("section-#{section_number.tr('.', '-')}", used_ids)
          used_ids << heading["id"]
          section_ids << heading["id"]
        end
      end

      doc.css("a[data-footnote-ref]").each do |anchor|
        enhance_reference_anchor(anchor, type: "footnote")
      end

      doc.css('a[href^="#"]').each do |anchor|
        next if anchor["data-footnote-ref"] || anchor["data-footnote-backref"]

        target_id = anchor["href"].delete_prefix("#")
        enhance_reference_anchor(anchor, type: "section") if section_ids.include?(target_id)
      end

      doc.css("section[data-footnotes]").each do |section|
        heading = Nokogiri::XML::Node.new("h2", doc)
        heading["class"] = "footnotes-title"
        heading.content = "References"
        section.prepend_child(heading)
      end

      doc.to_html
    end

    def markdown_to_plain_text(content)
      html = Commonmarker.to_html(content.to_s.encode("UTF-8"), options: { extension: EXTENSION_OPTIONS }, plugins: { syntax_highlighter: nil })
      Nokogiri::HTML::DocumentFragment.parse(html).text.squish
    end

    private

    REFERENCE_PREVIEW_ACTIONS = [
      "mouseenter->coplan--reference-preview#enter",
      "mouseleave->coplan--reference-preview#leave",
      "focus->coplan--reference-preview#enter",
      "blur->coplan--reference-preview#leave",
      "click->coplan--reference-preview#follow"
    ].join(" ").freeze

    def unique_dom_id(base, used_ids)
      return base unless used_ids.include?(base)

      suffix = 2
      suffix += 1 while used_ids.include?("#{base}-#{suffix}")
      "#{base}-#{suffix}"
    end

    def enhance_reference_anchor(anchor, type:)
      anchor.add_class("reference-anchor")
      anchor.add_class("reference-anchor--#{type}")
      anchor["aria-haspopup"] = "dialog"
      anchor["aria-expanded"] = "false"
      anchor["data-action"] = [ anchor["data-action"], REFERENCE_PREVIEW_ACTIONS ].compact.join(" ")
    end

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

    # Rewrites commonmarker's per-document footnote ids (#fn-N / #fnref-N)
    # and the hrefs that point at them so multiple fragments can coexist in
    # one DOM. Only ids/fragments with the fn-/fnref- shape are touched —
    # heading anchors and user-supplied ids pass through untouched.
    FOOTNOTE_ID_PATTERN = /\A(fn|fnref)-/

    def scope_footnote_ids(html, prefix)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      doc.css("[id]").each do |el|
        el["id"] = "#{prefix}-#{el["id"]}" if el["id"].match?(FOOTNOTE_ID_PATTERN)
      end
      doc.css(%(a[href^="#fn"])).each do |a|
        fragment = a["href"].delete_prefix("#")
        a["href"] = "##{prefix}-#{fragment}" if fragment.match?(FOOTNOTE_ID_PATTERN)
      end
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
