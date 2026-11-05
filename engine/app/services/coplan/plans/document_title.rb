module CoPlan
  module Plans
    # A document's opening top-level heading owns its name. Never search for
    # an H1 inside a quote, code fence, or presentation region.
    class DocumentTitle
      DEFAULT = "Untitled".freeze

      def self.call(content, fallback: DEFAULT, override: false, allow_empty: false)
        source = content.to_s.encode(Encoding::UTF_8).delete("\r")
        first = Markdown.parse(source).first_child
        heading = first if first&.type == :heading && first.header_level == 1
        fallback = fallback.to_s.gsub(/\s+/, " ").strip.presence || DEFAULT
        if heading
          lines = source.lines
          range = (heading.source_position[:start_line] - 1)..(heading.source_position[:end_line] - 1)
          heading_source = lines[range].join
          text = MarkdownTextExtractor.call(heading_source).first.strip
          # Drop leading blank lines and canonicalize Setext titles. The rich
          # editor must see the title as its first block in every document.
          unless heading_source.match?(/\A {0,3}#(?:[ \t]|\n|\z)/)
            heading_source = "# #{lines[range].take(range.size - 1).map(&:strip).join(' ')}\n"
          end
          source = heading_source + lines[(range.end + 1)..].to_a.join
          return source if !override && (text.present? || allow_empty)
          return source if override && text == fallback

          lines[range] = "# #{escape(fallback)}\n"
          lines.drop(range.begin).join
        else
          "# #{escape(fallback)}\n\n#{source}"
        end
      end

      def self.extract(content)
        content = content.to_s.encode(Encoding::UTF_8)
        first = Markdown.parse(content).first_child
        return DEFAULT unless first&.type == :heading && first.header_level == 1

        lines = content.lines[(first.source_position[:start_line] - 1)..(first.source_position[:end_line] - 1)]
        MarkdownTextExtractor.call(lines.join).first.gsub(/\s+/, " ").strip.presence || DEFAULT
      end

      def self.remap_input_sources(payload, original, normalized)
        return payload if original == normalized
        runs = WritingProvenance.input_runs(payload, original)
        return nil unless runs

        runs = WritingProvenance.remap(original, normalized, runs, [ [ normalized.length, "unknown" ] ])
        offset = 0
        { "runs" => runs.map { |length, kind|
          text = normalized[offset, length]
          offset += length
          [ text.encode(Encoding::UTF_16LE).bytesize / 2, kind ]
        } }
      end

      def self.escape(text)
        text.gsub(/([\\`*_{}\[\]<>()#!|~&])/) { |character| "\\#{character}" }
      end
    end
  end
end
