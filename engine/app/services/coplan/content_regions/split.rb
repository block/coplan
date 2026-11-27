module Coplan
  module ContentRegions
    # Standalone top-level paragraphs introduce regions. A presentation contains
    # Markdown; once a component opens, its body is opaque JavaScript.
    class Split
      Region = Struct.new(:kind, :source, :start_line, :end_line, :id, :theme, :attributes, keyword_init: true)
      Result = Struct.new(:regions, :canonical_source, :component_mask, keyword_init: true)
      OPEN = /\A::: \{\.presentation(?: #([a-zA-Z][\w-]*))?(?: theme="(coplan|graphite)")?\}\z/
      COMPONENT_PREFIX = "::: {.component"
      COMPONENT = /\A::: \{\.component(?: #([a-zA-Z][\w-]*))?((?: (?:title|type|uses|text-comments)="[^"\n]*")*)\}\z/
      CLOSE = ":::"

      def self.region_source?(source)
        source.include?("::: {.presentation") || source.include?(COMPONENT_PREFIX)
      end

      def self.component_mask(source)
        source.include?(COMPONENT_PREFIX) ? call(source).component_mask : source
      end

      def self.call(source)
        new(source).call
      end

      def initialize(source)
        @original_lines = source.to_s.encode("UTF-8").split("\n", -1)
        @lines = @original_lines.map { |line| line.delete_suffix("\r") }
      end

      def call
        reset_marker_scan(0)
        regions = []
        canonical = @original_lines.dup
        masked = @original_lines.dup
        cursor = 0
        index = 0
        while index < @lines.size
          region = declaration(@lines[index])
          if region && markdown_marker?(index)
            closing = (index + 1...@lines.size).find do |i|
              @lines[i] == CLOSE && (region.kind == :component || markdown_marker?(i))
            end
            break unless closing
            add_document(regions, cursor, index)
            region.start_line = index + 2
            region.end_line = closing + 1
            region.source = @lines[index + 1...closing].join("\n")
            regions << region
            if region.kind == :component
              (index..closing).each { |i| canonical[i] = masked[i] = blank_line(i) }
            else
              canonical[index] = blank_line(index)
              canonical[closing] = blank_line(closing)
            end
            cursor = closing + 1
            reset_marker_scan(cursor)
            index = cursor
          else
            index += 1
          end
        end
        add_document(regions, cursor, @lines.size)
        Result.new(regions:, canonical_source: canonical.join("\n"), component_mask: masked.join("\n"))
      end

      private

      def blank_line(index)
        blank = " " * @lines[index].length
        blank << "\r" if @original_lines[index].end_with?("\r")
        blank
      end

      def reset_marker_scan(offset)
        @scan_start = @scan_end = offset
        @scan_bytes = 0
      end

      # Start fresh after a confirmed region, so JavaScript never determines
      # the Markdown context after its closing marker. Grow the lookahead by
      # bytes when candidate markers inside code or quotes keep being rejected.
      def markdown_marker?(index)
        if index >= @scan_end
          budget = @scan_bytes * 2
          while @scan_end < @lines.size
            size = @lines[@scan_end].bytesize + 1
            break if @scan_end > index && @scan_bytes + size > budget
            @scan_bytes += size
            @scan_end += 1
          end
          # Include the following line to distinguish a standalone paragraph
          # from a continuation or setext heading at the edge of the window.
          @markers = paragraph_markers(@lines[@scan_start..@scan_end].join("\n"))
        end
        @markers.include?(index)
      end

      def paragraph_markers(source)
        markers = Set.new
        Coplan::Markdown.parse(source, options: { extension: MarkdownHelper::EXTENSION_OPTIONS }).each do |node|
          next unless node.type == :paragraph
          pos = node.source_position
          index = pos[:start_line] - 1 + @scan_start
          markers << index if pos[:start_line] == pos[:end_line] && @lines[index].start_with?(CLOSE)
        end
        markers
      end

      def declaration(line)
        if (match = OPEN.match(line))
          Region.new(kind: :presentation, id: match[1], theme: match[2] || "coplan")
        elsif (match = COMPONENT.match(line))
          pairs = match[2].scan(/ (title|type|uses|text-comments)="([^"]*)"/)
          Region.new(kind: :component, id: match[1], attributes: pairs.to_h) if pairs.to_h.size == pairs.size
        end
      end

      def add_document(regions, first, finish)
        source = @lines[first...finish].join("\n")
        regions << Region.new(kind: :document, source:, start_line: first + 1) unless source.empty?
      end
    end
  end
end
