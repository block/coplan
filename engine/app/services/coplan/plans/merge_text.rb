require "diff/lcs"

module CoPlan
  module Plans
    # A three-way, character-range merge. Both sides are compared with the
    # same immutable base. Only disjoint edits (or identical edits) combine.
    class MergeText
      class Conflict < StandardError; end

      def self.hunks(before, after)
        result = []
        position = 0
        pending = nil
        Diff::LCS.sdiff(before.each_char.to_a, after.each_char.to_a).each do |change|
          if change.action == "="
            result << pending if pending
            pending = nil
            position += 1
          else
            pending ||= { from: position, to: position, text: "" }
            unless change.action == "+"
              position += 1
              pending[:to] = position
            end
            pending[:text] += change.new_element unless change.action == "-"
          end
        end
        result << pending if pending
        result
      end

      def self.overlap?(left, right)
        if left[:from] == left[:to] && right[:from] == right[:to]
          left[:from] == right[:from]
        elsif left[:from] == left[:to]
          left[:from] > right[:from] && left[:from] < right[:to]
        elsif right[:from] == right[:to]
          right[:from] > left[:from] && right[:from] < left[:to]
        else
          left[:from] < right[:to] && right[:from] < left[:to]
        end
      end

      def self.call(base:, local:, remote:)
        return remote if local == base || local == remote
        return local if remote == base
        ours = hunks(base, local)
        theirs = hunks(base, remote)
        ours.each do |left|
          theirs.each do |right|
            raise Conflict, "Both edits change the same passage" if left != right && overlap?(left, right)
          end
        end
        merged = base.dup
        (ours + theirs).uniq.sort_by { |hunk| [ hunk[:from], hunk[:to] ] }.reverse_each do |hunk|
          merged[hunk[:from]...hunk[:to]] = hunk[:text]
        end
        merged
      end
    end
  end
end
