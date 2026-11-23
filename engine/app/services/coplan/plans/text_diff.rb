require "diff/lcs"

module Coplan
  module Plans
    # Character-offset replacements between two document versions. Skip common
    # edges, use LCS for small changes, and use a bounded Myers shortest-edit
    # search for larger changes. Never infer character positions from lines:
    # matching the wrong repeated line can misplace comments or concurrent edits.
    # If the search exhausts its budget, replace the entire changed middle.
    module TextDiff
      MAX_CHARACTER_CELLS = 1_000_000

      # One budget for the whole search, counting frontier states and character
      # comparisons. Stored frontier entries also consume this budget, bounding
      # the backtracking trace as well as CPU work.
      MAX_SEARCH_STEPS = 1_000_000

      module_function

      # [{ from:, to:, text: }]: replace before[from...to] with text.
      def hunks(before, after)
        return [] if before == after

        prefix = common_prefix_length(before, after)
        suffix = common_suffix_length(before, after, prefix)
        old_middle = before[prefix...(before.length - suffix)]
        new_middle = after[prefix...(after.length - suffix)]
        replacement = [ { from: prefix, to: prefix + old_middle.length, text: new_middle } ]
        return replacement if old_middle.empty? || new_middle.empty?
        return character_hunks(old_middle, new_middle, prefix) if small?(old_middle, new_middle)

        bounded_character_hunks(old_middle, new_middle, prefix) || replacement
      end

      # Myers' frontier records the furthest old-text position on each diagonal
      # after d insertions/deletions. An array index i represents diagonal 2*i-d.
      # Equal characters advance along a diagonal without another edit. A found
      # path is shortest; an exhausted search returns no partial alignment.
      def bounded_character_hunks(before, after, offset)
        return if [ before.length, after.length ].max > MAX_SEARCH_STEPS

        old = before.codepoints
        fresh = after.codepoints
        frontier = [ 0 ]
        trace = []
        steps = 0
        (0..old.length + fresh.length).each do |distance|
          next_frontier = []
          (0..distance).each do |index|
            steps += 1
            return if steps > MAX_SEARCH_STEPS

            insertion = index.zero? || (index < distance && frontier[index - 1] < frontier[index])
            x = insertion ? frontier[index] : frontier[index - 1] + 1
            y = x - (2 * index - distance)
            while x < old.length && y < fresh.length
              steps += 1
              return if steps > MAX_SEARCH_STEPS
              break unless old[x] == fresh[y]
              x += 1
              y += 1
            end
            next_frontier << x
            if x >= old.length && y >= fresh.length
              return backtrack(trace, old.length, fresh.length, fresh, after.encoding, offset)
            end
          end
          trace << next_frontier
          frontier = next_frontier
        end
      end

      def backtrack(trace, x, y, fresh, encoding, offset)
        edits = []
        trace.length.downto(1) do |distance|
          frontier = trace[distance - 1]
          diagonal = x - y
          index = (diagonal + distance) / 2
          insertion = index.zero? || (index < distance && frontier[index - 1] < frontier[index])
          previous_x = insertion ? frontier[index] : frontier[index - 1]
          previous_y = previous_x - (insertion ? diagonal + 1 : diagonal - 1)
          edits << { from: offset + previous_x, to: offset + previous_x + (insertion ? 0 : 1),
                     text: insertion ? fresh[previous_y].chr(encoding) : +"" }
          x, y = previous_x, previous_y
        end

        edits.reverse_each.with_object([]) do |edit, hunks|
          if hunks.last && hunks.last[:to] == edit[:from]
            hunks.last[:to] = edit[:to]
            hunks.last[:text] << edit[:text]
          else
            hunks << edit
          end
        end
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
