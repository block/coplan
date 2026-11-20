module CoPlan
  module Plans
    # A three-way, character-range merge. Both sides are compared with the
    # same immutable base. Only disjoint edits (or identical edits) combine.
    class MergeText
      class Conflict < StandardError; end

      def self.hunks(before, after)
        TextDiff.hunks(before, after)
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
