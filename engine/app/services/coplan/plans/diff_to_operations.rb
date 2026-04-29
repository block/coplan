require "diff/lcs"

module CoPlan
  module Plans
    # Converts (old_content, new_content) into an ordered array of replace_exact
    # operations whose application reproduces new_content exactly. Each op is
    # emitted with `_pre_resolved_ranges` already set (in the coordinate system
    # of the content state immediately BEFORE the op is applied), so it can be
    # fed straight into Plans::ApplyOperations without re-resolving positions.
    #
    # Granularity is line-level: consecutive non-equal lines in the LCS diff
    # are grouped into a single hunk, which becomes one replace_exact op. This
    # is the right granularity for two reasons:
    #
    #   1. Anchors in unchanged regions survive intact via the existing OT
    #      engine (Plans::TransformRange) — only anchors that overlap a
    #      changed hunk get marked out-of-date.
    #   2. The resulting operations_json on the new PlanVersion stays compact
    #      (one entry per hunk, not one per character), which keeps OT
    #      transforms cheap when later edits rebase through this version.
    #
    # Operations are emitted in left-to-right order over the OLD content, and
    # each `_pre_resolved_ranges` accounts for cumulative deltas from prior
    # ops in the sequence — so applying them via ApplyOperations one after
    # another produces correct positional metadata on every op.
    class DiffToOperations
      def self.call(old_content:, new_content:)
        new(old_content: old_content, new_content: new_content).call
      end

      def initialize(old_content:, new_content:)
        @old_content = old_content || ""
        @new_content = new_content || ""
      end

      def call
        return [] if @old_content == @new_content

        old_lines = @old_content.lines
        new_lines = @new_content.lines

        # offsets[i] = character offset of the start of line i (offsets[len] = total chars).
        # Positions throughout the codebase (anchor_start/anchor_end, resolved_range, etc.)
        # are character offsets, NOT byte offsets — so unicode is handled correctly.
        old_offsets = build_line_offsets(old_lines)
        new_offsets = build_line_offsets(new_lines)

        sdiff = Diff::LCS.sdiff(old_lines, new_lines)
        hunks = group_hunks(sdiff)

        cumulative_delta = 0

        hunks.map do |hunk|
          old_start, old_end = char_range(hunk[:old_lines], hunk[:old_anchor], old_offsets)
          new_start, new_end = char_range(hunk[:new_lines], hunk[:new_anchor], new_offsets)

          old_text = @old_content[old_start...old_end] || ""
          new_text = @new_content[new_start...new_end] || ""

          # Shift positions to account for prior ops' deltas. Because hunks
          # are emitted left-to-right and don't overlap, all prior ops are
          # strictly before this one — a simple cumulative shift is exact.
          adjusted_start = old_start + cumulative_delta
          adjusted_end = old_end + cumulative_delta

          op = {
            "op" => "replace_exact",
            "old_text" => old_text,
            "new_text" => new_text,
            "_pre_resolved_ranges" => [[adjusted_start, adjusted_end]]
          }

          cumulative_delta += new_text.length - old_text.length
          op
        end
      end

      private

      def build_line_offsets(lines)
        offsets = [0]
        running = 0
        lines.each do |line|
          running += line.length
          offsets << running
        end
        offsets
      end

      # Groups consecutive non-"=" sdiff entries into hunks. Each hunk
      # records the line indexes it touches on each side. Pure insertions
      # have an empty :old_lines list; pure deletions have an empty
      # :new_lines list — those use the recorded anchor as a zero-width
      # insertion point in that side.
      def group_hunks(sdiff)
        hunks = []
        current_old = []
        current_new = []
        current_old_anchor = nil
        current_new_anchor = nil
        in_hunk = false

        flush = lambda do
          if in_hunk
            hunks << {
              old_lines: current_old.any? ? (current_old.min..current_old.max).to_a : [],
              new_lines: current_new.any? ? (current_new.min..current_new.max).to_a : [],
              old_anchor: current_old_anchor,
              new_anchor: current_new_anchor
            }
            current_old = []
            current_new = []
            current_old_anchor = nil
            current_new_anchor = nil
            in_hunk = false
          end
        end

        sdiff.each do |ctx|
          if ctx.action == "="
            flush.call
            next
          end

          in_hunk = true
          current_old_anchor ||= ctx.old_position
          current_new_anchor ||= ctx.new_position
          current_old << ctx.old_position if %w[- !].include?(ctx.action)
          current_new << ctx.new_position if %w[+ !].include?(ctx.action)
        end

        flush.call
        hunks
      end

      # Returns [start, end] character offsets for a hunk's line list. For a
      # pure insertion/deletion (empty line list), uses the anchor as a
      # zero-width range at offsets[anchor].
      def char_range(line_indexes, anchor, offsets)
        return [offsets[anchor], offsets[anchor]] if line_indexes.empty?
        first = line_indexes.first
        last = line_indexes.last
        [offsets[first], offsets[last + 1]]
      end
    end
  end
end
