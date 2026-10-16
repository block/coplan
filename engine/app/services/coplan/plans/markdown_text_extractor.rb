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
      def self.call(content, exclude_nonprose: false, source_spans: false)
        new(content, exclude_nonprose:, source_spans:).call
      end

      def initialize(content, exclude_nonprose: false, source_spans: false)
        @content = content.to_s.include?("::: {.presentation") ? ContentRegions::Split.call(content).canonical_source : content
        @exclude_nonprose = exclude_nonprose
        @source_lines = @content.lines if exclude_nonprose || source_spans
        @source_spans = [] if source_spans
        if source_spans
          @source_line_offsets = [ 0 ]
          @source_lines.each { |line| @source_line_offsets << @source_line_offsets.last + line.length }
        end
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

        @source_spans ? [ stripped, pos_map, @source_spans ] : [ stripped, pos_map ]
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
          map[byte_offset + char.bytesize - 1] = char_idx if @source_spans
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
          next if @exclude_nonprose && nonprose?(child)

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
          when :html_block
            append_html_block(child, stripped, pos_map) if @source_spans
          when :text
            pos = @source_spans && node.type == :escaped ? node.source_position : child.source_position
            start_byte = line_byte_offsets[pos[:start_line]] + pos[:start_column] - 1
            char_idx = byte_to_char[start_byte]
            if @source_spans
              end_byte = line_byte_offsets[pos[:end_line]] + pos[:end_column] - 1
              append_decoded_text(child.string_content, char_idx, byte_to_char[end_byte], stripped, pos_map)
            else
              child.string_content.each_char.with_index do |char, i|
                stripped << char
                pos_map << (char_idx + i)
              end
            end
          when :code
            if @source_spans
              append_inline_code(child, line_byte_offsets, byte_to_char, stripped, pos_map)
              next
            end
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
              append_source_span(char, content_char_start + i)
            end
          when :code_block
            if @source_spans
              append_code_block(child, stripped, pos_map)
              next
            end
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
                append_source_span(char, char_idx + i)
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
            append_source_span("\n", byte_to_char[start_byte])
          else
            extract_text_nodes(child, line_byte_offsets, byte_to_char, stripped, pos_map)
          end
        end
      end

      ENTITY = /\A&(?:\#[0-9]{1,7}|\#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/.freeze

      # A rendered character can consume multiple raw characters (\* or
      # &amp;). Preserve that entire span so later text cannot drift, and a
      # mixed-origin entity cannot falsely inherit only its leading '&'.
      def append_decoded_text(text, first, last, stripped, pos_map)
        decoded, spans = decoded_source(first, last)
        append_span_text(text, decoded == text ? spans : nil, stripped, pos_map)
      end

      def decoded_source(first, last, markdown_escapes: true)
        raw = @content[first..last].to_s.chars
        decoded, spans, cursor = +"", [], 0
        while cursor < raw.length
          length, value = 1, raw[cursor]
          following = raw[cursor + 1]
          if markdown_escapes && value == "\\" && following&.ascii_only? && following.match?(/[[:punct:]]/)
            length, value = 2, following
          elsif value == "&" && (entity = ENTITY.match(raw[cursor, 34].join))
            length = entity[0].length
            @entities ||= {}
            value = (@entities[entity[0]] ||= Commonmarker.parse(entity[0]).first_child.first_child.string_content)
            length, value = 1, "&" if value == entity[0]
          end
          decoded << value
          value.each_char { spans << [ first + cursor, first + cursor + length ] }
          cursor += length
        end
        [ decoded, spans ]
      end

      def append_span_text(text, spans, stripped, pos_map)
        text.each_char.with_index do |char, index|
          span = spans ? spans.fetch(index) : [ -1, -1 ]
          stripped << char
          pos_map << span.first
          @source_spans << span
        end
      end

      HTML_TAG = /<!--.*?(?:-->|\z)|<\/?[A-Za-z][\w:-]*(?:[^>"']|"[^"]*"|'[^']*')*>|<![^>]*>|<\?[^>]*\?>/m.freeze

      def append_html_block(node, stripped, positions)
        pos = node.source_position
        first = @source_line_offsets.fetch(pos[:start_line] - 1) +
          @source_lines.fetch(pos[:start_line] - 1).byteslice(0, pos[:start_column] - 1).length
        last = @source_line_offsets.fetch(pos[:end_line] - 1) +
          @source_lines.fetch(pos[:end_line] - 1).byteslice(0, pos[:end_column]).length
        raw = @content[first...last]
        safe = ApplicationController.helpers.sanitize(raw, tags: MarkdownHelper::ALLOWED_TAGS, attributes: MarkdownHelper::ALLOWED_ATTRIBUTES)
        visible = Nokogiri::HTML5.fragment(safe.to_s).text
        return if visible.empty?

        candidate, spans, cursor = +"", [], 0
        append_text = lambda do |stop|
          if stop > cursor
            text, source = decoded_source(first + cursor, first + stop - 1, markdown_escapes: false)
            candidate << text
            spans.concat(source)
          end
        end
        raw.to_enum(:scan, HTML_TAG).each do
          match = Regexp.last_match
          append_text.call(match.begin(0))
          cursor = match.end(0)
        end
        append_text.call(raw.length)
        # Sanitization can remove or repair markup. Only attribute an exact
        # match; never search past removed text for an identical later word.
        append_span_text(visible, candidate == visible ? spans : nil, stripped, positions)
      end

      def append_source_span(char, position)
        return unless @source_spans

        @source_spans << (position && @content[position] == char ? [ position, position + 1 ] : [ -1, -1 ])
      end

      def append_inline_code(node, lines, bytes, stripped, positions)
        pos = node.source_position
        first = bytes[lines[pos[:start_line]] + pos[:start_column] - 1]
        last = bytes[lines[pos[:end_line]] + pos[:end_column] - 1]
        chars = @content[first..last].chars.each_with_index.to_a
        left, right = 0, chars.length
        left += 1 while chars[left]&.first == "`"
        right -= 1 while right > left && chars[right - 1]&.first == "`"
        chars = chars[left...right]
        chars.map! { |char, index| [ char == "\n" ? " " : char, index ] }
        if chars.first&.first == " " && chars.last&.first == " " && chars.any? { |char, _| char != " " }
          chars.shift
          chars.pop
        end
        valid = chars.map(&:first).join == node.string_content
        node.string_content.each_char.with_index do |char, index|
          position = valid ? first + chars.fetch(index).last : -1
          stripped << char
          positions << position
          append_source_span(char, position >= 0 ? position : nil)
        end
      end

      def append_code_block(node, stripped, positions)
        pos = node.source_position
        first_line = pos[:start_line] - 1
        opening = @source_lines[first_line].to_s[(pos[:start_column] - 1)..]
        # Indented code can itself start with literal fence characters.
        fenced = opening&.match?(/\A(?:`{3,}|~{3,})/) &&
          (node.fence_info.present? || node.string_content.lines.first.to_s.chomp != opening.chomp)
        first_line += 1 if fenced
        node.string_content.lines.each_with_index do |text, index|
          line = @source_lines[first_line + index].to_s.chomp
          body = text.chomp
          first = line.end_with?(body) ? @source_line_offsets[first_line + index] + line.length - body.length : nil
          text.each_char.with_index do |char, offset|
            position = first && first + offset
            stripped << char
            positions << (position || -1)
            append_source_span(char, position)
          end
        end
      end

      # Match the writing inspector's DOM exclusions. Keeping diagram source,
      # image alt text, or hidden definitions in its search stream can assign
      # their authors to an identical paragraph later in the document. Source
      # positions still refer to the original Markdown, including skipped text.
      def nonprose?(node)
        return true if %i[image footnote_definition].include?(node.type)
        return true if node.type == :code_block && node.fence_info.to_s.split.first == "mermaid"
        return false unless node.type == :paragraph

        pos = node.source_position
        pos[:start_line] == pos[:end_line] && ContentRegions::Iframe.call(@source_lines[pos[:start_line] - 1].to_s.chomp)
      end

      # Appends a synthetic separator character to the stripped text.
      # Maps it to -1 since it doesn't correspond to any raw source position.
      def append_separator(stripped, pos_map, char)
        stripped << char
        pos_map << -1
        @source_spans << [ -1, -1 ] if @source_spans
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
