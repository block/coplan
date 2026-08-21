module CoPlan
  module Slideshows
    # Assigns one slide a layout pattern and a type-scale step, implementing
    # docs/SLIDE_SPEC.md — the spec's conformance examples are this class's
    # acceptance tests (spec/services/slideshows/conformance_spec.rb).
    #
    # A pure function: markdown in, classification out. No CoPlan models, no
    # rendering, no measurement — layout must be deterministic so the same
    # content produces the same deck on every render, and simple enough that
    # an authoring agent can compose with the rules deliberately.
    class Classify
      Classification = Struct.new(:pattern, :step, :media, :lead, keyword_init: true)

      # A paragraph at most this long can ride along with a featured block
      # as a subtitle, kicker, caption, or attribution. Longer text is the
      # slide's content, and the featured block loses the stage.
      SHORT_TEXT = 160

      # One unit approximates one rendered line of body text.
      CHARS_PER_UNIT = 60
      IMAGE_UNITS = 3
      # A mermaid fence renders as a fit-to-box diagram, so it bills like
      # media, not like its source line count.
      MERMAID_UNITS = 4
      # deck.css renders code at 0.8em with 1.55 line-height — about
      # five-sixths of a 1.5-em body line per code line, not half of one.
      CODE_LINES_PER_UNIT = 1.2
      OPAQUE_HTML_UNITS = 2

      # Comment boundaries follow the HTML parser that decides what renders:
      # `<!-->` and `<!--->` are complete (empty) comments, a normal comment
      # runs to the next `-->`.
      HTML_COMMENT = /<!-->|<!--->|<!--.*?-->/m

      # Cumulative unit ceilings for steps 1–3; past the last is step 4,
      # the floor — beyond it content is reported (fit report), not clipped.
      STEP_CEILINGS = [ 5, 9, 14 ].freeze

      def self.call(source)
        new(source).call
      end

      def initialize(source)
        @source = source.to_s.encode("UTF-8").delete("\r")
      end

      def call
        blocks = content_sequence
        pattern, media = match_pattern(blocks)
        Classification.new(pattern:, media:, step: step_for(blocks),
                           lead: blocks.first&.type == :heading)
      end

      private

      # The slide's top-level blocks minus what never influences layout:
      # comment-only HTML blocks (speaker notes, the renderer's preamble
      # sentinel) and footnote definitions (back matter, not slide content).
      def content_sequence
        doc = Commonmarker.parse(@source, options: { extension: MarkdownHelper::EXTENSION_OPTIONS })
        doc.each.reject do |node|
          node.type == :footnote_definition ||
            (node.type == :html_block && comment_only?(node))
        end
      end

      def comment_only?(node)
        # to_commonmark: raw-HTML nodes have no string_content accessor,
        # and for raw HTML the commonmark serialization IS the raw source.
        # A comment opened but never closed swallows the rest of the block,
        # exactly as it does in a browser — either way, nothing renders.
        rest = node.to_commonmark.gsub(HTML_COMMENT, "")
        rest.strip.empty? || rest.lstrip.start_with?("<!--")
      end

      # The catalog's decision list — SLIDE_SPEC.md "The pattern catalog",
      # same order, first match wins.
      def match_pattern(blocks)
        lead = blocks.first if blocks.first&.type == :heading
        body = lead ? blocks.drop(1) : blocks

        return [ :title, nil ] if lead && body.empty?
        return [ :title, nil ] if lead && body.size == 1 && short_paragraph?(body.first)

        if (featured = featured_block(body))
          return [ :stage, nil ] if media_block?(featured)
          return [ :code,  nil ] if featured.type == :code_block
          return [ :quote, nil ] if featured.type == :block_quote
          return [ :table, nil ] if featured.type == :table
        end

        return [ :columns, nil ] if body.size == 2 && body.all? { |block| block.type == :list }

        if body.size >= 2 && body.count { |block| media_block?(block) } == 1
          return [ :split, :leading ]  if media_block?(body.first)
          return [ :split, :trailing ] if media_block?(body.last)
        end

        [ :content, nil ]
      end

      # The body's single featured block, when the body is that block alone
      # or that block plus one adjacent short paragraph (kicker or caption).
      def featured_block(body)
        case body.size
        when 1 then body.first
        when 2
          return body.last if short_paragraph?(body.first)

          body.first if short_paragraph?(body.last)
        end
      end

      def media_block?(node)
        return true if node.type == :code_block && node.fence_info.to_s.split.first == "mermaid"
        return false unless node.type == :paragraph

        images = 0
        node.each do |inline|
          case inline.type
          when :image
            images += 1
          when :link
            children = inline.each.to_a
            return false unless children.size == 1 && children.first.type == :image

            images += 1
          when :text
            return false unless inline.string_content.strip.empty?
          when :softbreak, :linebreak
            # whitespace between inlines
          when :html_inline
            # An inline comment beside the image is a speaker note, not
            # content — comments never influence layout.
            return false unless comment_only?(inline)
          else
            return false
          end
        end
        images == 1
      end

      # Hard breaks count as a full line's worth of characters: six
      # hard-broken agenda lines are not a subtitle however few glyphs
      # they hold.
      def short_paragraph?(node)
        node.type == :paragraph && image_count(node).zero? &&
          plain_text(node).length + CHARS_PER_UNIT * hard_break_count(node) <= SHORT_TEXT
      end

      # Visible characters only: image alt text renders as an attribute,
      # zero glyphs on the canvas, so the walk never descends into an image
      # (its rendered cost is exactly its IMAGE_UNITS).
      def plain_text(node)
        text = +""
        each_visible_inline(node) do |inline|
          text << inline.string_content if %i[text code].include?(inline.type)
        end
        text
      end

      def each_visible_inline(node, &block)
        yield node
        return if node.type == :image

        node.each { |child| each_visible_inline(child, &block) }
      end

      def step_for(blocks)
        total = blocks.sum { |block| units(block) }
        index = STEP_CEILINGS.index { |ceiling| total <= ceiling }
        index ? index + 1 : STEP_CEILINGS.size + 1
      end

      # One unit ≈ one rendered line — SLIDE_SPEC.md "The type scale".
      def units(node)
        case node.type
        when :heading
          1
        when :paragraph
          text_units(node) + hard_break_count(node) + IMAGE_UNITS * image_count(node)
        when :code_block
          return MERMAID_UNITS if media_block?(node)

          [ node.string_content.count("\n"), 1 ].max.fdiv(CODE_LINES_PER_UNIT).ceil
        when :table
          node.each.count
        when :thematic_break
          1
        when :html_block
          comment_only?(node) ? 0 : OPAQUE_HTML_UNITS
        when :footnote_definition
          0
        when :list, :item, :taskitem, :block_quote
          [ node.each.sum { |child| units(child) }, 1 ].max
        else
          1
        end
      end

      def text_units(node)
        [ plain_text(node).length.fdiv(CHARS_PER_UNIT).ceil, 1 ].max
      end

      # A hard line break forces a rendered line just as CHARS_PER_UNIT
      # characters do.
      def hard_break_count(node)
        count = 0
        each_visible_inline(node) { |inline| count += 1 if inline.type == :linebreak }
        count
      end

      def image_count(node)
        count = 0
        each_visible_inline(node) { |inline| count += 1 if inline.type == :image }
        count
      end
    end
  end
end
