module Coplan
  module Plans
    # A three-way, character-range merge. Both sides are compared with the
    # same immutable base. Only edits separated by unchanged text (or
    # identical edits) combine: like diff3, edits that touch conflict, since
    # "twice daily" and "weekly" made from "daily" must not become
    # "twice weekly".
    class MergeText
      class Conflict < StandardError; end

      def self.hunks(before, after)
        TextDiff.hunks(before, after)
      end

      # Ranges are half-open, so a shared endpoint means the edits touch.
      def self.overlap?(left, right)
        left[:from] <= right[:to] && right[:from] <= left[:to]
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
