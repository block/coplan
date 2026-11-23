require "diff/lcs"

module Coplan
  module Plans
    # Hunks between two versions of a document, in character offsets of the
    # older one. A character LCS costs time and memory proportional to the
    # product of the two lengths, and web saves run it while holding the plan
    # row lock, so it is only ever run on text small enough to be cheap:
    #
    #   1. The common prefix and suffix are skipped (one linear scan).
    #   2. If one side of what remains is empty, it is one hunk.
    #   3. If what remains is small, it gets a character diff.
    #   4. Otherwise lines are diffed first, and each changed run of lines
    #      is refined the same way; a run too large stays one hunk.
    #   5. If even the line diff would be slow, the whole middle is one hunk.
    #
    # A coarser hunk can turn a merge into a conflict, never into a splice.
    module TextDiff
      # Cells (old length x new length) a character diff may cost. About a
      # tenth of a second with Diff::LCS; matches WritingProvenance.
      MAX_CHARACTER_CELLS = 1_000_000

      # A line LCS costs about one step per pair of equal lines, so mostly
      # unique prose is cheap at any length, while thousands of blank or
      # repeated lines are not. A million pairs is about a quarter second.
      MAX_LINE_MATCHES = 1_000_000

      module_function

      # [{ from:, to:, text: }]: replace before[from...to] with text.
      def hunks(before, after)
        return [] if before == after

        prefix = common_prefix_length(before, after)
        suffix = common_suffix_length(before, after, prefix)
        old_middle = before[prefix...(before.length - suffix)]
        new_middle = after[prefix...(after.length - suffix)]
        return refine(old_middle, new_middle, prefix) if small?(old_middle, new_middle)
        return [ { from: prefix, to: prefix + old_middle.length, text: new_middle } ] if line_matches(old_middle, new_middle) > MAX_LINE_MATCHES

        line_hunks(old_middle, new_middle).flat_map do |old_from, old_to, new_from, new_to|
          refine(old_middle[old_from...old_to], new_middle[new_from...new_to], prefix + old_from)
        end
      end

      # One replacement of before by after, split by character when cheap.
      def refine(before, after, offset)
        if !before.empty? && !after.empty? && small?(before, after)
          character_hunks(before, after, offset)
        else
          [ { from: offset, to: offset + before.length, text: after } ]
        end
      end

      def line_matches(before, after)
        new_counts = after.lines.tally
        before.lines.tally.sum { |line, count| count * new_counts.fetch(line, 0) }
      end

      # [[old_from, old_to, new_from, new_to]]: runs of changed whole lines,
      # as character offsets into each side. A pure insertion or deletion is
      # an empty range at the line where it happens.
      def line_hunks(before, after)
        old_lines = before.lines
        new_lines = after.lines
        old_offsets = line_offsets(old_lines)
        new_offsets = line_offsets(new_lines)
        groups = []
        current = nil
        Diff::LCS.sdiff(old_lines, new_lines).each do |change|
          if change.action == "="
            groups << current if current
            current = nil
            next
          end
          current ||= { old: [], new: [], old_anchor: change.old_position, new_anchor: change.new_position }
          current[:old] << change.old_position if %w[- !].include?(change.action)
          current[:new] << change.new_position if %w[+ !].include?(change.action)
        end
        groups << current if current
        groups.map do |group|
          [ *offset_range(group[:old], group[:old_anchor], old_offsets),
            *offset_range(group[:new], group[:new_anchor], new_offsets) ]
        end
      end

      def character_hunks(before, after, offset)
        result = []
        position = offset
        pending = nil
        Diff::LCS.sdiff(before.each_char.to_a, after.each_char.to_a).each do |change|
          if change.action == "="
            result << pending if pending
            pending = nil
            position += 1
          else
            pending ||= { from: position, to: position, text: +"" }
            unless change.action == "+"
              position += 1
              pending[:to] = position
            end
            pending[:text] << change.new_element unless change.action == "-"
          end
        end
        result << pending if pending
        result
      end

      def small?(before, after)
        before.length * after.length <= MAX_CHARACTER_CELLS
      end

      def common_prefix_length(before, after, limit = [ before.length, after.length ].min)
        # String#[] at successive character indexes rescans UTF-8 from the
        # start. Walk characters once so non-ASCII documents stay linear too.
        characters = after.each_char
        length = 0
        before.each_char do |character|
          break if length == limit || character != characters.next
          length += 1
        end
        length
      end

      def common_suffix_length(before, after, prefix)
        limit = [ before.length, after.length ].min - prefix
        common_prefix_length(before.reverse, after.reverse, limit)
      end

      def line_offsets(lines)
        lines.each_with_object([ 0 ]) { |line, offsets| offsets << offsets.last + line.length }
      end

      def offset_range(indexes, anchor, offsets)
        return [ offsets[anchor], offsets[anchor] ] if indexes.empty?

        [ offsets[indexes.min], offsets[indexes.max + 1] ]
      end
    end
  end
end
