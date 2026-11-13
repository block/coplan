module CoPlan
  module MarkdownHelper
    include EmbedsHelper
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

    ALLOWED_ATTRIBUTES = %w[id class lang href src alt title width target rel type start checked disabled open aria-label aria-haspopup aria-expanded data-line data-line-text data-action data-mention-username data-sourcepos data-reference-type data-footnotes data-footnote-ref data-footnote-backref data-footnote-backref-idx data-math-style].freeze

    # Commonmarker extensions beyond the gem defaults (tables, tasklist,
    # strikethrough, autolink stay on). Footnotes: `[^1]` in text plus a
    # `[^1]: definition` block anywhere in the document. Alerts use a first
    # quote line such as `[!NOTE]` (see render_callouts; `[!SUMMARY]` is
    # Coplan's own, see CoPlan::Markdown). Math uses `$inline$`,
    # `$$display$$`, `` $`inline`$ `` and math fences, typeset by KaTeX.
    # comrak's dollar rules keep currency ("$5 and $10") as text.
    EXTENSION_OPTIONS = { footnotes: true, alerts: true, math_dollars: true, math_code: true }.freeze

    CALLOUT_TYPES = %w[note tip important warning caution summary].freeze

    # Fence languages the reading view shows rendered, with a Source toggle.
    MARKDOWN_BLOCK_LANGUAGES = %w[markdown md].freeze

    # The only elements and values comrak emits for math. Anything else
    # carrying the attribute (authored HTML) loses it during rendering.
    MATH_ELEMENTS = %w[span code pre].freeze
    MATH_STYLES = %w[inline display].freeze

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

    # footnote_prefix: pass a DOM-unique string when a page renders more than
    # one markdown fragment (e.g. each comment) — commonmarker numbers
    # footnote ids from #fn-1 per document, so unprefixed fragments collide
    # and reference/backref links jump to the wrong footnote.
    #
    # line_offset: pass the fragment's 0-based starting line in the full
    # document when rendering a slice of a larger plan (slideshow slides).
    # Checkbox toggles write to source lines by number, so their data-line
    # must stay document-absolute even when the render sees only a fragment.
    #
    # data_tables: wrap tables in their scroll frame and give them the
    # spreadsheet expander. Decks opt out — a slide is a fixed, scaled
    # artifact whose typography the deck layout engine already owns, and a
    # nested scroll frame inside a transformed slide belongs to nobody.
    #
    # expandable_images: frame each image with the same full-window expander
    # diagrams and tables use. Follows data_tables by default, so decks opt
    # out of both together.
    def render_markdown(content, interactive: true, footnote_prefix: nil, footnotes: :inline, line_offset: 0, data_tables: true, expandable_images: data_tables, source_comments: false, retain_sourcepos: false)
      render_options = { unsafe: true }
      # Sourcepos wires checkboxes and structural comment targets to source,
      # and tells parser-generated math from authored HTML that imitates it;
      # it is stripped after generating trusted interaction metadata.
      source = content.to_s.encode("UTF-8")
      render_options[:sourcepos] = true if interactive || retain_sourcepos || source.include?(ContentRegions::Iframe::PREFIX) || source.include?("$") || source.include?("math")
      html = CoPlan::Markdown.to_html(source, options: { extension: EXTENSION_OPTIONS, render: render_options }, plugins: { syntax_highlighter: nil })
      with_chips = transform_mention_anchors(html)
      with_references = transform_reference_anchors(with_chips, numbered_sections: footnote_prefix.nil?)
      scrubber = LinkScrubber.new
      scrubber.tags = ALLOWED_TAGS
      scrubber.attributes = ALLOWED_ATTRIBUTES
      sanitized = sanitize(with_references, scrubber: scrubber)
      sanitized = prepare_math(sanitized, source)
      sanitized = render_iframe_blocks(sanitized, content.to_s)
      sanitized = render_callouts(sanitized)
      result = interactive ? make_checkboxes_interactive(sanitized, content, line_offset: line_offset, source_comments: source_comments, retain_sourcepos: retain_sourcepos) : sanitized
      unless interactive || retain_sourcepos
        fragment = Nokogiri::HTML::DocumentFragment.parse(result)
        fragment.css("[data-sourcepos]").each { |node| node.remove_attribute("data-sourcepos") }
        result = fragment.to_html
      end
      result = scope_footnote_ids(result, footnote_prefix) if footnote_prefix
      result = select_footnotes(result, footnotes)
      return result.html_safe if footnotes == :only

      result = wrap_data_tables(result) if data_tables
      result = wrap_expandable_images(result) if expandable_images
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
    # that the target is a Coplan heading would create incorrect links.
    #
    # Footnote citations and valid numbered-section links opt into the shared
    # reference-preview controller. It reads their already-rendered targets,
    # so previews require no duplicate citation data or network request.
    def transform_reference_anchors(html, numbered_sections: true)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      used_ids = doc.css("[id]").filter_map { |node| node["id"].presence }.to_set
      section_ids = Set.new

      # `own_host` is what lets a readable Coplan address be recognized
      # here: /sam/liveorder/cart-roadmap is shaped like any other site's
      # URL, so being on our own host is the whole distinction.
      own_host = request&.host
      doc.css("a[href]").each do |anchor|
        next unless anchor["href"].match?(%r{\Ahttps?://}i)

        anchor["target"] = "_blank"
        anchor["rel"] = "noopener noreferrer"
        anchor["data-reference-type"] = Reference.classify_url(anchor["href"], own_host: own_host)
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
      source = content.to_s.encode("UTF-8")
      source = ContentRegions::Split.call(source).canonical_source if source.include?("::: {.presentation")
      html = CoPlan::Markdown.to_html(source, options: { extension: EXTENSION_OPTIONS }, plugins: { syntax_highlighter: nil })
      fragment = Nokogiri::HTML::DocumentFragment.parse(html)
      fragment.css("p.markdown-alert-title").remove
      fragment.text.squish
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

    def select_footnotes(html, mode)
      return html if mode == :inline

      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      # A rendered Markdown block keeps its own footnotes next to its body.
      sections = doc.css("section[data-footnotes]").reject { |section| section.ancestors("[data-markdown-block-rendered]").any? }
      if mode == :only
        sections.map(&:to_html).join
      elsif mode == :exclude
        sections.each(&:remove)
        doc.to_html
      else
        raise ArgumentError, "unknown footnote mode: #{mode.inspect}"
      end
    end

    # Math elements become self-rendering: each one connects the KaTeX
    # controller, so every surface that renders Markdown (documents,
    # comments, previews, decks, footnote sections) typesets math, and a
    # page without math never loads KaTeX. Runs after sanitization because
    # it writes data-controller, which authored markup may not set.
    #
    # Only math the parser produced keeps data-math-style. Authored HTML can
    # write the same attribute (and even a data-sourcepos), so an element
    # must sit at the unique source position of a math node in the AST —
    # the same rule SourceTargets applies to diagram targets. Anything else
    # loses the attribute and stays ordinary, anchorable text, matching
    # MarkdownTextExtractor, which counts authored HTML text as prose.
    def prepare_math(html, source)
      return html unless html.include?("data-math-style")

      positions = math_positions(source)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      nodes = doc.css("[data-math-style]")
      counts = nodes.map { |node| node["data-sourcepos"] }.tally
      nodes.each do |node|
        position = node["data-sourcepos"]
        kind = node.name == "pre" ? :fence : :inline
        if MATH_ELEMENTS.include?(node.name) && MATH_STYLES.include?(node["data-math-style"]) &&
            positions[kind].include?(position) && counts[position] == 1
          node["data-controller"] = "coplan--math"
        else
          node.remove_attribute("data-math-style")
        end
      end
      doc.to_html
    end

    # Source positions ("line:col-line:col", as comrak writes data-sourcepos)
    # of the math nodes and math fences the parser found.
    def math_positions(source)
      positions = { inline: Set.new, fence: Set.new }
      CoPlan::Markdown.parse(source, options: { extension: EXTENSION_OPTIONS }).walk do |node|
        kind = if node.type == :math then :inline
        elsif node.type == :code_block && node.fence_info == "math" then :fence
        end
        next unless kind

        p = node.source_position
        positions[kind] << "#{p[:start_line]}:#{p[:start_column]}-#{p[:end_line]}:#{p[:end_column]}"
      end
      positions
    end

    # Wires rendered task checkboxes to their source lines via Commonmarker's
    # sourcepos metadata, so the parser that decides what renders as a
    # checkbox is also the authority on which line it came from. A checkbox
    # only becomes interactive when its own source line matches
    # TASK_LINE_PATTERN. Sourcepos lines are fragment-relative; line_offset
    # shifts the emitted data-line back to document coordinates.
    def make_checkboxes_interactive(html, content, line_offset: 0, source_comments: false, retain_sourcepos: false)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      source_lines = content.to_s.each_line.map(&:rstrip)
      if source_comments && line_offset.zero?
        Plans::SourceTargets.new(content).annotate(doc)
        render_markdown_blocks(doc, content)
      end

      doc.css('input[type="checkbox"]').each do |cb|
        li = cb.ancestors("li").first
        line_number = sourcepos_start_line(li)
        next unless line_number

        line_text = source_lines[line_number - 1]
        next unless line_text&.match?(TASK_LINE_PATTERN)

        cb.remove_attribute("disabled")
        cb["data-action"] = "coplan--checkbox#toggle"
        cb["data-line-text"] = line_text
        cb["data-line"] = (line_number + line_offset).to_s

        li.add_class("task-list-item")

        # The <label> wraps only the checkbox, never the task text: selecting
        # text to comment on it must not tick the box. The label's padding
        # keeps a comfortable hit target around the small native box. Keep
        # the rendered task body in one flex item so inline elements such as
        # <code> participate in normal inline flow instead of becoming
        # separate columns alongside the checkbox.
        row = Nokogiri::XML::Node.new("div", doc)
        row["class"] = "task-list-item-row"
        hit_area = Nokogiri::XML::Node.new("label", doc)
        hit_area["class"] = "task-list-item-checkbox"
        task_body = Nokogiri::XML::Node.new("span", doc)
        task_body["class"] = "task-list-item-content"

        li.children.to_a.each do |child|
          if child == cb
            hit_area.add_child(child)
          else
            task_body.add_child(child)
          end
        end
        row.add_child(hit_area)
        row.add_child(task_body)
        li.add_child(row)

        cb["aria-label"] = task_checkbox_name(task_body)

        ul = li.parent
        ul.add_class("task-list") if ul&.name == "ul"
      end

      doc.css("[data-sourcepos]").each do |el|
        position = /\A(\d+):(\d+)-(\d+):(\d+)\z/.match(el["data-sourcepos"])
        if retain_sourcepos && position && position[1].to_i + line_offset > 0 && position[3].to_i + line_offset > 0
          el["data-sourcepos"] = "#{position[1].to_i + line_offset}:#{position[2]}-#{position[3].to_i + line_offset}:#{position[4]}"
        else
          el.remove_attribute("data-sourcepos")
        end
      end
      doc.to_html
    end

    TASK_NAME_BLOCK_TAGS = %w[ul ol pre blockquote table div hr h1 h2 h3 h4 h5 h6].freeze

    # Matches the rich editor's "Task: <first paragraph>" name so a
    # checkbox is announced the same way in view and edit mode.
    def task_checkbox_name(task_body)
      first = task_body.children.find { |child| !(child.text? && child.text.strip.empty?) }
      if first&.name == "p"
        nodes = first.children
      else
        nodes = task_body.children.take_while { |child| !TASK_NAME_BLOCK_TAGS.include?(child.name) }
      end

      text = nodes.map { |node| task_name_text(node) }.join.squish
      text.empty? ? "Task" : "Task: #{text}"
    end

    def task_name_text(node)
      return node.text if node.text?
      return "" unless node.element?
      return "" if node.name == "sup" && node.classes.include?("footnote-ref")
      return node["alt"].to_s if node.name == "img"

      node.children.map { |child| task_name_text(child) }.join
    end

    # Commonmarker renders an alert as a div with a title paragraph. The
    # title moves into data-callout-title, which the stylesheet shows beside
    # the type's icon, so the label adds no text to the document. Comment
    # anchors and occurrence counts then match the source text, where the
    # `[!NOTE]` marker is not prose either.
    #
    # This runs after sanitization because data-callout-title is not an
    # attribute authors may write. Raw HTML can copy Commonmarker's alert
    # markup, which gives the same callout the marker gives, but it cannot
    # set the callout classes directly: those are removed first.
    def render_callouts(html)
      return html unless html.include?("callout") || html.include?("markdown-alert")

      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      doc.css("[class*='callout']").each do |node|
        classes = node.classes.reject { |name| name.match?(/\Acallout(?:--|\z)/) }
        if classes.empty?
          node.remove_attribute("class")
        else
          node["class"] = classes.join(" ")
        end
      end

      doc.css("div.markdown-alert").each do |alert|
        type = CALLOUT_TYPES.find { |name| alert.classes.include?("markdown-alert-#{name}") }
        title = alert.element_children.first
        next unless type && title&.name == "p" && title.classes == [ "markdown-alert-title" ]

        title.remove
        alert["class"] = "callout callout--#{type}"
        alert["data-callout-title"] = title.text.squish
      end

      doc.to_html
    end

    # A table is a block of data, not a paragraph. Each one gets a scroll
    # frame — so a wide table can't run off the page the way it does bare —
    # and the Stimulus controller that pins its header, fades its edges, and
    # opens it as a full-screen spreadsheet.
    #
    # This runs after sanitization on purpose: the frame carries
    # data-controller and data-*-target attributes that document markup is
    # deliberately never allowed to write for itself. It adds structure
    # only, never text, so comment anchors — which count occurrences in the
    # rendered text — see exactly what they saw before.
    def wrap_data_tables(html)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      # A Markdown block's rendered pane already wrapped its own tables.
      tables = doc.css("table").reject { |table| table.ancestors("table, [data-markdown-block-rendered]").any? }
      return html if tables.empty?

      tables.each do |table|
        grid = doc.document.create_element("div", class: "data-grid",
                                                 "data-controller" => "coplan--data-grid",
                                                 "data-action" => "dblclick->coplan--data-grid#expandFromDoubleClick")
        frame = doc.document.create_element("div", class: "data-grid__frame",
                                                  "data-coplan--data-grid-target" => "frame")
        table.add_previous_sibling(grid)
        grid.add_child(frame)
        frame.add_child(table)
      end

      doc.to_html
    end

    # Each image gets a frame that carries the expand affordance and opens
    # the image full-window on the same pan/zoom surface diagrams use. Like
    # the table frame, this runs after sanitization because it writes
    # data-controller attributes, and it adds structure only, so comment
    # anchors never see a text change. When an image is a link's only
    # content, the frame wraps the link, so the expand button sits outside
    # the anchor. When the link also has text or several images, each frame
    # sits inside the link.
    def wrap_expandable_images(html)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      images = doc.css("img").reject { |image| image.ancestors("[data-markdown-block-rendered]").any? }
      return html if images.empty?

      images.each do |image|
        link = image.parent if image.parent&.name == "a" && image.parent.element_children.one? && image.parent.text.strip.empty?
        target = link || image
        frame = doc.document.create_element("span", class: "image-frame",
                                                   "data-controller" => "coplan--image-expand",
                                                   "data-action" => "dblclick->coplan--image-expand#expandFromDoubleClick")
        image["data-coplan--image-expand-target"] = "image"
        image["data-action"] = [ image["data-action"], "load->coplan--image-expand#measure" ].compact.join(" ")
        target.add_previous_sibling(frame)
        frame.add_child(target)
        paragraph = frame.parent
        if paragraph.name == "p" && frame.xpath("preceding-sibling::node()").all? { |sibling| sibling.text? && sibling.text.strip.empty? }
          paragraph.add_class("image-paragraph")
        end
      end

      doc.to_html
    end

    # In the reading view, a `markdown` or `md` fence shows its body
    # rendered, with a toggle back to the literal source. The source <pre>
    # stays in the DOM, hidden, and remains the text that comment anchors
    # count and match, so the document's anchor text model (and the
    # server's, MarkdownTextExtractor) is the same whichever view shows.
    # The rendered pane is kept out of that model; its block elements carry
    # data-markdown-from/to, body-relative character offsets that let the
    # browser map a rendered selection or highlight to the source.
    #
    # Like math, only a fence the parser produced qualifies: authored HTML
    # can imitate the lang and sourcepos, so the <pre> must sit at the
    # unique position of a markdown code block in the AST.
    def render_markdown_blocks(doc, content)
      pres = doc.css("pre[lang][data-sourcepos]").select do |pre|
        MARKDOWN_BLOCK_LANGUAGES.include?(pre["lang"].downcase) && pre.ancestors(".deck-region, [data-markdown-block]").none?
      end
      return doc if pres.empty?

      positions = markdown_block_positions(content)
      counts = pres.map { |pre| pre["data-sourcepos"] }.tally
      pres.each_with_index do |pre, index|
        next unless positions.include?(pre["data-sourcepos"]) && counts[pre["data-sourcepos"]] == 1

        code = pre.element_children.find { |child| child.name == "code" }
        next unless code

        block = doc.document.create_element("div", class: "markdown-block", "data-markdown-block" => "",
          "data-controller" => "coplan--markdown-block")
        bar = doc.document.create_element("div", class: "markdown-block__bar", "data-markdown-block-chrome" => "")
        bar.add_child(doc.document.create_element("span", pre["lang"], class: "markdown-block__label"))
        views = doc.document.create_element("div", class: "markdown-block__views", role: "group", "aria-label" => "Markdown view")
        { "rendered" => "Rendered", "source" => "Source" }.each do |view, label|
          views.add_child(doc.document.create_element("button", label, type: "button", class: "markdown-block__view",
            "aria-pressed" => (view == "rendered").to_s, "data-view" => view,
            "data-coplan--markdown-block-target" => "button", "data-action" => "coplan--markdown-block#show"))
        end
        bar.add_child(views)
        rendered = doc.document.create_element("div", class: "markdown-block__rendered", "data-markdown-block-rendered" => "",
          "data-coplan--markdown-block-target" => "rendered")
        rendered.inner_html = render_markdown_block_body(code.text, index + 1)

        pre.add_previous_sibling(block)
        pre["hidden"] = ""
        pre["data-markdown-block-source"] = ""
        pre["data-coplan--markdown-block-target"] = "source"
        block.add_child(bar)
        block.add_child(rendered)
        block.add_child(pre)
      end
      doc
    end

    # Source positions of the fences that render as Markdown blocks.
    def markdown_block_positions(content)
      positions = Set.new
      CoPlan::Markdown.parse(content.to_s.encode("UTF-8"), options: { extension: EXTENSION_OPTIONS }).walk do |node|
        next unless node.type == :code_block && MARKDOWN_BLOCK_LANGUAGES.include?(node.fence_info.to_s.split.first&.downcase)

        p = node.source_position
        positions << "#{p[:start_line]}:#{p[:start_column]}-#{p[:end_line]}:#{p[:end_column]}"
      end
      positions
    end

    # A block's body renders read-only: no task toggles (their lines are
    # not document lines), no outline headings or heading ids (they would
    # collide with the document's), no table expander, and footnotes scoped
    # to the block.
    def render_markdown_block_body(body, number)
      # Tables stay plain: the expanded table view has no way to comment on
      # a draft's cells, and in the pane a selection maps to the source.
      html = render_markdown(body, interactive: false, retain_sourcepos: true, footnote_prefix: "markdown-block-#{number}",
        data_tables: false, expandable_images: true)
      wrapper = Nokogiri::HTML::DocumentFragment.parse(html).element_children.find { |node| node.name == "div" && node.classes.include?("markdown-rendered") }
      inner = Nokogiri::HTML::DocumentFragment.parse(wrapper ? wrapper.inner_html : html)
      inner.css(%w[h1 h2 h3 h4 h5 h6].map { |heading| "#{heading} a.anchor[id]" }.join(", ")).each do |anchor|
        anchor.remove if anchor.text.strip.empty?
      end
      lines = body.lines
      offsets = [ 0 ]
      lines.each { |line| offsets << offsets.last + line.length }
      # Browsers index strings in UTF-16 code units, Ruby in characters.
      # They differ after a character outside the BMP, such as an emoji.
      astral = body.match?(/[^\u0000-\uFFFF]/)
      utf16 = ->(offset) { astral ? body[0, offset].encode("UTF-16LE").bytesize / 2 : offset }
      inner.css("[data-sourcepos]").each do |element|
        range = Plans::SourceTargets.char_range(element["data-sourcepos"], lines, offsets)
        element.remove_attribute("data-sourcepos")
        next unless range

        element["data-markdown-from"], element["data-markdown-to"] = range.map { |offset| utf16.call(offset).to_s }
      end
      inner.to_html
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
