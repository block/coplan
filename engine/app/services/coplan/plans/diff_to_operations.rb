module Coplan
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
    # `granularity: :character` (web saves) compares characters directly so
    # a one-word edit stays one word. Plans::TextDiff bounds the search cost
    # and falls back to one replacement if the budget is exhausted.
    #
    # Operations are emitted in left-to-right order over the OLD content, and
    # each `_pre_resolved_ranges` accounts for cumulative deltas from prior
    # ops in the sequence — so applying them via ApplyOperations one after
    # another produces correct positional metadata on every op.
    class DiffToOperations
      def self.call(old_content:, new_content:, granularity: :line)
        new(old_content: old_content, new_content: new_content, granularity: granularity).call
      end

      def initialize(old_content:, new_content:, granularity: :line)
        @granularity = granularity
        @old_content = old_content || ""
        @new_content = new_content || ""
      end

      def call
        return [] if @old_content == @new_content

        # Positions throughout the codebase (anchor_start/anchor_end, resolved_range, etc.)
        # are character offsets, NOT byte offsets — so unicode is handled correctly.
        replacements =
          if @granularity == :character
            TextDiff.hunks(@old_content, @new_content).map { |hunk| [ hunk[:from], hunk[:to], hunk[:text] ] }
          else
            TextDiff.line_hunks(@old_content, @new_content).map do |old_from, old_to, new_from, new_to|
              [ old_from, old_to, @new_content[new_from...new_to] ]
            end
          end

        cumulative_delta = 0

        replacements.map do |old_start, old_end, new_text|
          old_text = @old_content[old_start...old_end] || ""

          # Shift positions to account for prior ops' deltas. Because hunks
          # are emitted left-to-right and don't overlap, all prior ops are
          # strictly before this one — a simple cumulative shift is exact.
          adjusted_start = old_start + cumulative_delta
          adjusted_end = old_end + cumulative_delta

          op = {
            "op" => "replace_exact",
            "old_text" => old_text,
            "new_text" => new_text,
            "_pre_resolved_ranges" => [ [ adjusted_start, adjusted_end ] ]
          }

          cumulative_delta += new_text.length - old_text.length
          op
        end
      end
    end
  end
end
