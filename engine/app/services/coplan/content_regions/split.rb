module CoPlan
  module ContentRegions
    # Standalone top-level paragraphs introduce regions. A presentation contains
    # Markdown; once a component opens, its body is opaque JavaScript.
    class Split
      Region = Struct.new(:kind, :source, :start_line, :end_line, :id, :theme, :attributes, keyword_init: true)
      Result = Struct.new(:regions, :canonical_source, :component_mask, keyword_init: true)
      OPEN = /\A::: \{\.presentation(?: #([a-zA-Z][\w-]*))?(?: theme="(coplan|graphite)")?\}\z/
      COMPONENT_PREFIX = "::: {.component"
      COMPONENT = /\A::: \{\.component(?: #([a-zA-Z][\w-]*))?((?: (?:title|type|uses)="[^"\n]*")*)\}\z/
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
        @lines = source.to_s.encode("UTF-8").delete("\r").split("\n", -1)
      end

      def call
        markers = markdown_markers(0)
        regions = []
        canonical = @lines.dup
        masked = @lines.dup
        cursor = 0
        index = 0
        while index < @lines.size
          region = markers.include?(index) && declaration(@lines[index])
          if region
            closing = (index + 1...@lines.size).find do |i|
              @lines[i] == CLOSE && (region.kind == :component || markers.include?(i))
            end
            break unless closing
            add_document(regions, cursor, index)
            region.start_line = index + 2
            region.end_line = closing + 1
            region.source = @lines[index + 1...closing].join("\n")
            regions << region
            canonical[index] = " " * @lines[index].length
            canonical[closing] = " " * @lines[closing].length
            if region.kind == :component
              (index..closing).each { |i| masked[i] = canonical[i] = " " * @lines[i].length }
              # A Markdown-looking string inside JS can consume later lines in
              # the initial AST. Resume parsing in document context at the end.
              markers = markdown_markers(closing + 1) unless markers.include?(closing)
            end
            cursor = closing + 1
            index = cursor
          else
            index += 1
          end
        end
        add_document(regions, cursor, @lines.size)
        Result.new(regions:, canonical_source: canonical.join("\n"), component_mask: masked.join("\n"))
      end

      private

      def markdown_markers(offset)
        markers = Set.new
        CoPlan::Markdown.parse(@lines[offset..].join("\n"), options: { extension: MarkdownHelper::EXTENSION_OPTIONS }).each do |node|
          next unless node.type == :paragraph
          pos = node.source_position
          index = pos[:start_line] - 1 + offset
          markers << index if pos[:start_line] == pos[:end_line] && @lines[index].start_with?(CLOSE)
        end
        markers
      end

      def declaration(line)
        if (match = OPEN.match(line))
          Region.new(kind: :presentation, id: match[1], theme: match[2] || "coplan")
        elsif (match = COMPONENT.match(line))
          pairs = match[2].scan(/ (title|type|uses)="([^"]*)"/)
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
