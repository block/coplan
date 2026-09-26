module CoPlan
  module ContentRegions
    # A small fenced-div extension over CommonMark. Only standalone top-level
    # paragraphs can be delimiters, so code examples and quoted fences remain
    # ordinary Markdown. Unknown or unclosed fences remain visible source.
    class Split
      Region = Struct.new(:kind, :source, :start_line, :id, :theme, keyword_init: true)
      Result = Struct.new(:regions, :canonical_source, keyword_init: true)

      OPEN = /\A::: \{\.presentation(?: #([a-zA-Z][\w-]*))?(?: theme="(coplan|graphite)")?\}\z/
      CLOSE = ":::"

      def self.call(source)
        new(source).call
      end

      def initialize(source)
        @source = source.to_s.encode("UTF-8").delete("\r")
      end

      def call
        lines = @source.split("\n", -1)
        markers = {}
        Commonmarker.parse(@source, options: { extension: MarkdownHelper::EXTENSION_OPTIONS }).each do |node|
          next unless node.type == :paragraph
          pos = node.source_position
          next unless pos[:start_line] == pos[:end_line]

          line = lines[pos[:start_line] - 1]
          markers[pos[:start_line]] = line if line == CLOSE || line.match?(OPEN)
        end

        regions = []
        canonical = lines.dup
        cursor = 1
        opener = nil
        markers.sort.each do |number, line|
          if opener
            next unless line == CLOSE

            add_region(regions, lines, :document, cursor, opener[:line] - 1)
            add_region(regions, lines, :presentation, opener[:line] + 1, number - 1,
                       id: opener[:id], theme: opener[:theme])
            # Spaces keep every later source offset unchanged for comment
            # anchors and checkbox writes, while parsing as blank Markdown.
            canonical[opener[:line] - 1] = " " * lines[opener[:line] - 1].length
            canonical[number - 1] = " " * lines[number - 1].length
            cursor = number + 1
            opener = nil
          elsif (match = OPEN.match(line))
            opener = { line: number, id: match[1], theme: match[2] || "coplan" }
          end
        end
        add_region(regions, lines, :document, cursor, lines.length)
        Result.new(regions:, canonical_source: canonical.join("\n"))
      end

      private

      def add_region(regions, lines, kind, first, last, id: nil, theme: nil)
        return if first > last

        source = lines[(first - 1)..(last - 1)].join("\n")
        regions << Region.new(kind:, source:, start_line: first, id:, theme:) unless source.empty?
      end
    end
  end
end
