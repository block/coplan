module CoPlan
  module Plans
    # Extracts plain text from markdown using the Commonmarker AST, returning
    # [stripped_string, position_map] where position_map[i] is the character
    # index in the raw content of stripped_string[i].
    #
    # This handles all markdown constructs: inline formatting (`**`, `*`, `` ` ``,
    # `~~`), tables, links, images, lists, blockquotes, headings, etc.
    #
    # Usage:
    #   stripped, pos_map = MarkdownTextExtractor.call("Hello **world**")
    #   # stripped  => "Hello world"
    #   # pos_map   => [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12]
    class MarkdownTextExtractor
      def self.call(content)
        new(content).call
      end

      def initialize(content)
        @content = content
      end

      def call
        # Parsed with the renderer's own extensions. Reading the page with a
        # different grammar than we wrote it with is how `[^note]` ended up
        # here verbatim while the reader saw a superscript number — and a
        # comment selected across that citation could never be placed.
        doc = Commonmarker.parse(@content, options: { extension: MarkdownHelper::EXTENSION_OPTIONS })
        byte_to_char = build_byte_to_char_map
        line_byte_offsets = build_line_byte_offsets
        stripped = +""
        pos_map = []
        @footnote_numbers = {}

        extract_text_nodes(doc, line_byte_offsets, byte_to_char, stripped, pos_map)

        [ stripped, pos_map ]
      end

      private

      # Builds a map from byte offset to character index. Commonmarker reports
      # source positions using byte-based columns, but Ruby string indexing
      # uses character positions.
      def build_byte_to_char_map
        map = {}
        byte_offset = 0
        @content.each_char.with_index do |char, char_idx|
          map[byte_offset] = char_idx
          byte_offset += char.bytesize
        end
        map
      end

      # Builds an array mapping 1-based line numbers to byte offsets.
      # line_byte_offsets[line_number] = byte offset of the first byte on that line.
      def build_line_byte_offsets
        offsets = [ nil, 0 ] # index 0 unused; line 1 starts at byte 0
        byte_offset = 0
        @content.each_char do |char|
          byte_offset += char.bytesize
          offsets << byte_offset if char == "\n"
        end
        offsets
      end

      # Block-level node types that should be separated by newlines.
      BLOCK_TYPES = %i[paragraph heading table table_row item block_quote list code_block].to_set.freeze

      # Recursively walks the AST, appending text content to `stripped` and
      # character-index mappings to `pos_map`. Inserts whitespace between
      # block elements and table cells to match browser DOM text behavior.
      def extract_text_nodes(node, line_byte_offsets, byte_to_char, stripped, pos_map)
        prev_was_block = false

        node.each do |child|
          # Insert a space between adjacent table cells, and a newline
          # between block-level siblings (paragraphs, rows, items, etc.).
          if child.type == :table_cell
            append_separator(stripped, pos_map, " ") if prev_was_block
            prev_was_block = true
          elsif BLOCK_TYPES.include?(child.type)
            append_separator(stripped, pos_map, "\n") if prev_was_block
            prev_was_block = true
          end

          case child.type
          when :text
            pos = child.source_position
            start_byte = line_byte_offsets[pos[:start_line]] + pos[:start_column] - 1
            char_idx = byte_to_char[start_byte]
            child.string_content.each_char.with_index do |char, i|
              stripped << char
              pos_map << (char_idx + i)
            end
          when :code
            # source_position includes backtick delimiters; find the inner
            # content start by scanning past them in the raw string.
            pos = child.source_position
            start_byte = line_byte_offsets[pos[:start_line]] + pos[:start_column] - 1
            node_char_start = byte_to_char[start_byte]
            end_byte = line_byte_offsets[pos[:end_line]] + pos[:end_column] - 1
            node_char_end = byte_to_char[end_byte]
            text = child.string_content
            node_char_len = node_char_end - node_char_start + 1
            tick_len = (node_char_len - text.length) / 2
            content_char_start = node_char_start + tick_len
            text.each_char.with_index do |char, i|
              stripped << char
              pos_map << (content_char_start + i)
            end
          when :code_block
            # Fenced code blocks: source_position spans from the opening
            # fence to the closing fence. The string_content is the inner
            # text (excluding fences). Content starts on the line after
            # the opening fence.
            pos = child.source_position
            text = child.string_content
            content_line = pos[:start_line] + 1
            if content_line <= line_byte_offsets.length - 1
              content_byte = line_byte_offsets[content_line]
              char_idx = byte_to_char[content_byte]
              text.each_char.with_index do |char, i|
                stripped << char
                pos_map << (char_idx + i)
              end
            end
          when :footnote_reference
            # The reader sees the number the renderer assigned, so that is
            # what a selection sweeping across the citation carries. Its
            # digits are sentinels: no character of "[^note]" spells "1", and
            # a selection that merely ends on the marker should resolve back
            # to the prose before it rather than to half a citation.
            marker = footnote_number(child, line_byte_offsets, byte_to_char).to_s
            marker.each_char { |char| append_separator(stripped, pos_map, char) }
          when :softbreak, :linebreak
            pos = child.source_position
            start_byte = line_byte_offsets[pos[:start_line]] + pos[:start_column] - 1
            stripped << "\n"
            pos_map << byte_to_char[start_byte]
          else
            extract_text_nodes(child, line_byte_offsets, byte_to_char, stripped, pos_map)
          end
        end
      end

      # Appends a synthetic separator character to the stripped text.
      # Maps it to -1 since it doesn't correspond to any raw source position.
      def append_separator(stripped, pos_map, char)
        stripped << char
        pos_map << -1
      end

      # The number the renderer prints for this citation. Commonmarker counts
      # by first reference rather than by definition order, and a label cited
      # twice keeps its original number, so the count is keyed on the label —
      # which the node itself won't hand over, but its source span will.
      def footnote_number(node, line_byte_offsets, byte_to_char)
        pos = node.source_position
        start_char = byte_to_char[line_byte_offsets[pos[:start_line]] + pos[:start_column] - 1]
        end_char = byte_to_char[line_byte_offsets[pos[:end_line]] + pos[:end_column] - 1]
        return "" unless start_char && end_char

        label = @content[start_char..end_char].to_s.delete_prefix("[^").delete_suffix("]")
        @footnote_numbers[label] ||= @footnote_numbers.size + 1
      end
    end
  end
end
