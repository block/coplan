module CoPlan
  module Plans
    class PositionResolver
      Resolution = Data.define(:op, :ranges)

      def self.call(content:, operation:)
        new(content:, operation:).call
      end

      def initialize(content:, operation:)
        @content = content
        @op = operation.transform_keys(&:to_s)
      end

      def call
        case @op["op"]
        when "replace_exact"
          resolve_replace_exact
        when "insert_under_heading"
          resolve_insert_under_heading
        when "delete_paragraph_containing"
          resolve_delete_paragraph_containing
        else
          raise OperationError, "Unknown operation: #{@op["op"]}"
        end
      end

      private

      def resolve_replace_exact
        old_text = @op["old_text"]
        raise OperationError, "replace_exact requires 'old_text'" if old_text.blank?
        raise OperationError, "replace_exact requires 'new_text'" if @op["new_text"].nil?

        replace_all = @op["replace_all"] == true
        occurrence = (@op["occurrence"] || 1).to_i
        raise OperationError, "replace_exact: occurrence must be >= 1, got #{occurrence}" if occurrence < 1

        ranges = find_all_occurrences(old_text)

        if ranges.empty?
          raise OperationError, "replace_exact found 0 occurrences of the specified text"
        end

        if replace_all
          Resolution.new(op: "replace_exact", ranges: ranges)
        else
          count = @op["count"]&.to_i
          if count && count > 1
            Resolution.new(op: "replace_exact", ranges: ranges)
          else
            if !@op.key?("occurrence") && !@op.key?("replace_all") && ranges.length > 1 && (!count || count == 1)
              raise OperationError, "replace_exact found #{ranges.length} occurrences, expected at most 1"
            end

            if occurrence > ranges.length
              raise OperationError, "replace_exact: occurrence #{occurrence} requested but only #{ranges.length} found"
            end

            Resolution.new(op: "replace_exact", ranges: [ranges[occurrence - 1]])
          end
        end
      end

      def resolve_insert_under_heading
        heading = @op["heading"]
        raise OperationError, "insert_under_heading requires 'heading'" if heading.blank?
        raise OperationError, "insert_under_heading requires 'content'" if @op["content"].nil?

        pattern = /^#{Regexp.escape(heading)}[^\S\n]*$/
        matches = []
        @content.scan(pattern) do
          match_end = Regexp.last_match.end(0)
          matches << [match_end, match_end]
        end

        if matches.empty?
          raise OperationError, "insert_under_heading found no heading matching '#{heading}'"
        end

        if matches.length > 1
          raise OperationError, "insert_under_heading found #{matches.length} headings matching '#{heading}'"
        end

        Resolution.new(op: "insert_under_heading", ranges: matches)
      end

      def resolve_delete_paragraph_containing
        needle = @op["needle"]
        raise OperationError, "delete_paragraph_containing requires 'needle'" if needle.blank?

        paragraphs = locate_paragraphs
        matching = paragraphs.select { |para| para[:text].include?(needle) }

        if matching.empty?
          raise OperationError, "delete_paragraph_containing found no paragraph containing '#{needle}'"
        end

        if matching.length > 1
          raise OperationError, "delete_paragraph_containing found #{matching.length} paragraphs containing '#{needle}'"
        end

        para = matching.first
        ranges = [deletion_range_for(para, paragraphs)]

        Resolution.new(op: "delete_paragraph_containing", ranges: ranges)
      end

      def find_all_occurrences(text)
        ranges = []
        start_pos = 0
        while (idx = @content.index(text, start_pos))
          ranges << [idx, idx + text.length]
          start_pos = idx + text.length
        end
        ranges
      end

      # Locate each paragraph's text and its position in the content.
      # Paragraphs are separated by 2+ newlines. We track where each
      # paragraph's text starts/ends and the separator that follows it.
      def locate_paragraphs
        return [] if @content.empty?

        paragraphs = []
        scanner_pos = 0

        # Skip leading blank lines
        if (m = @content.match(/\A(\n+)/, scanner_pos))
          scanner_pos = m.end(0)
        end

        while scanner_pos < @content.length
          # Find the end of paragraph text (next \n\n or end of string)
          next_sep = @content.index(/\n{2,}/, scanner_pos)

          if next_sep
            text_end = next_sep
            # Find end of separator
            sep_match = @content.match(/\n{2,}/, next_sep)
            sep_end = sep_match.end(0)
          else
            text_end = @content.length
            sep_end = @content.length
          end

          text = @content[scanner_pos...text_end]
          paragraphs << { text: text, text_start: scanner_pos, text_end: text_end, sep_end: sep_end }

          scanner_pos = sep_end
        end

        paragraphs
      end

      # Determine the character range to delete so that removing
      # content[range[0]...range[1]] produces clean output with
      # correct paragraph spacing.
      def deletion_range_for(para, all_paragraphs)
        idx = all_paragraphs.index(para)
        is_first = idx == 0
        is_last = idx == all_paragraphs.length - 1

        if all_paragraphs.length == 1
          # Only paragraph — delete everything
          [0, @content.length]
        elsif is_first
          # First paragraph: delete from text_start through the separator after it,
          # so the next paragraph becomes the start.
          [para[:text_start], para[:sep_end]]
        elsif is_last
          # Last paragraph: delete from the separator before it (end of previous
          # paragraph's text) to the end of this paragraph's text.
          prev = all_paragraphs[idx - 1]
          [prev[:text_end], para[:text_end]]
        else
          # Middle paragraph: delete from end of previous paragraph's text
          # through the separator after this paragraph, but keep one separator
          # between the previous and next paragraphs.
          # Simplest: delete from previous text_end to this paragraph's sep_end,
          # then the next paragraph starts right there. But we need to preserve
          # one separator. Instead: delete this paragraph's text_start through
          # sep_end. That removes the paragraph and its trailing separator, and
          # the separator before it (from previous text_end to this text_start)
          # becomes the separator between prev and next.
          [para[:text_start], para[:sep_end]]
        end
      end
    end
  end
end
