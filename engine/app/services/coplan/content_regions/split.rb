module CoPlan
  module ContentRegions
    # A small fenced-div extension over CommonMark. Only standalone top-level
    # paragraphs can be delimiters, so code examples and quoted fences remain
    # ordinary Markdown. Unknown or unclosed fences remain visible source.
    #
    # A summary block is ordinary Markdown between two marker lines. Authors
    # write it without blank lines (`- Last point` then `:::`), where
    # CommonMark would fold the closer into the list item, so its markers are
    # whole lines outside code and raw HTML rather than paragraphs. Only the
    # first closed block counts; later ones stay visible source. It cannot
    # contain a presentation: an opener before the summary's closer leaves
    # the summary marker as text, so the closer still belongs to the deck.
    class Split
      Region = Struct.new(:kind, :source, :start_line, :id, :theme, keyword_init: true)
      Summary = Struct.new(:open_line, :close_line, keyword_init: true)
      Result = Struct.new(:regions, :canonical_source, :summary, keyword_init: true)

      OPEN = /\A::: \{\.presentation(?: #([a-zA-Z][\w-]*))?(?: theme="(coplan|graphite)")?\}\z/
      SUMMARY_OPEN = "::: {.summary}"
      CLOSE = ":::"
      PLAIN_TEXT_BLOCKS = %i[paragraph heading item table_row table_cell block_quote].freeze

      def self.call(source)
        new(source).call
      end

      # Cheap pre-check before parsing: whether the source can contain a
      # marker this class would treat as structure.
      def self.applies?(source)
        source.to_s.include?("::: {.presentation") || source.to_s.include?(SUMMARY_OPEN)
      end

      # Markdown for rendering a summary block: its marker lines become
      # thematic breaks of the same length. A break ends any list, table or
      # paragraph above it, as a blank line would not, and leaves every source
      # offset and line ending in place. `summary` is in this source's lines.
      def self.with_summary_breaks(source, summary)
        lines = source.to_s.split("\n", -1)
        [ summary.open_line, summary.close_line ].each do |number|
          line = lines[number - 1]
          ending = line.end_with?("\r") ? "\r" : ""
          lines[number - 1] = "***".ljust(line.length - ending.length) + ending
        end
        lines.join("\n")
      end

      # The summary block's reading text for previews and unfurls, or nil when
      # the plan has no block or the block has no text. Citation markers,
      # images and HTML tags are not part of the sentence a reader sees.
      def self.summary_text(source)
        return unless source.to_s.include?(SUMMARY_OPEN)

        result = new(source).call
        summary = result.summary
        return unless summary

        document = CoPlan::Markdown.parse(result.canonical_source, options: { extension: MarkdownHelper::EXTENSION_OPTIONS })
        text = document.select do |node|
          node.source_position[:start_line] > summary.open_line && node.source_position[:end_line] < summary.close_line
        end.map { |node| plain_text(node) }.join(" ")
        text.squish.presence
      end

      def self.plain_text(node)
        case node.type
        when :text, :code then node.string_content
        when :code_block then " #{node.string_content} "
        when :softbreak, :linebreak then " "
        when :footnote_reference, :footnote_definition, :image, :html_inline, :html_block then ""
        else
          inner = node.map { |child| plain_text(child) }.join
          PLAIN_TEXT_BLOCKS.include?(node.type) ? " #{inner} " : inner
        end
      end
      private_class_method :plain_text

      def initialize(source)
        @source = source.to_s.encode("UTF-8").delete("\r")
      end

      def call
        lines = @source.split("\n", -1)
        document = CoPlan::Markdown.parse(@source, options: { extension: MarkdownHelper::EXTENSION_OPTIONS })
        markers = {}
        document.each do |node|
          next unless node.type == :paragraph
          pos = node.source_position
          next unless pos[:start_line] == pos[:end_line]

          line = lines[pos[:start_line] - 1]
          markers[pos[:start_line]] = { line:, paragraph: true } if line == CLOSE || line.match?(OPEN)
        end
        if @source.include?(SUMMARY_OPEN)
          literal = literal_lines(document)
          lines.each.with_index(1) do |line, number|
            next unless line == SUMMARY_OPEN || line == CLOSE
            markers[number] ||= { line:, paragraph: false } unless literal.include?(number)
          end
        end

        regions = []
        canonical = lines.dup
        cursor = 1
        opener = nil
        summary_opener = nil
        summary = nil
        markers.sort.each do |number, marker|
          line = marker[:line]
          if opener
            next unless marker[:paragraph] && line == CLOSE

            add_region(regions, lines, :document, cursor, opener[:line] - 1)
            add_region(regions, lines, :presentation, opener[:line] + 1, number - 1,
                       id: opener[:id], theme: opener[:theme])
            # Spaces keep every later source offset unchanged for comment
            # anchors and checkbox writes, while parsing as blank Markdown.
            canonical[opener[:line] - 1] = " " * lines[opener[:line] - 1].length
            canonical[number - 1] = " " * lines[number - 1].length
            cursor = number + 1
            opener = nil
          elsif marker[:paragraph] && (match = OPEN.match(line))
            summary_opener = nil
            opener = { line: number, id: match[1], theme: match[2] || "coplan" }
          elsif summary_opener && line == CLOSE
            summary = Summary.new(open_line: summary_opener, close_line: number)
            summary_opener = nil
          elsif line == SUMMARY_OPEN && summary.nil? && summary_opener.nil?
            summary_opener = number
          end
        end
        add_region(regions, lines, :document, cursor, lines.length)
        canonical_source = canonical.join("\n")
        canonical_source = self.class.with_summary_breaks(canonical_source, summary) if summary
        Result.new(regions:, canonical_source:, summary:)
      end

      private

      # Lines that Markdown shows verbatim: code and raw HTML blocks at any
      # depth. A marker written there is an example, not structure.
      def literal_lines(document)
        lines = Set.new
        document.walk do |node|
          next unless %i[code_block html_block].include?(node.type)

          lines.merge(node.source_position[:start_line]..node.source_position[:end_line])
        end
        lines
      end

      def add_region(regions, lines, kind, first, last, id: nil, theme: nil)
        return if first > last && kind != :presentation

        source = first > last ? "" : lines[(first - 1)..(last - 1)].join("\n")
        regions << Region.new(kind:, source:, start_line: first, id:, theme:) if kind == :presentation || !source.empty?
      end
    end
  end
end
