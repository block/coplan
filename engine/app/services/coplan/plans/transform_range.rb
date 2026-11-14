module CoPlan
  module Plans
    # Operational Transform engine for character-range transformations.
    #
    # INVARIANT: Every PlanVersion's operations_json entries MUST contain
    # positional metadata (resolved_range + new_range/delta, or replacements).
    # All content edits flow through Plans::ApplyOperations which stores this
    # data. There are no legacy or non-positional edit paths.
    #
    # If an operation lacks positional metadata, transform_through_versions
    # raises Conflict rather than silently skipping it.
    class TransformRange
      class Conflict < StandardError; end

      # Transform a range [s, e] through an edit that replaced [s2, e2] with text of length new_length.
      # Returns the transformed [s, e] or raises Conflict if ranges overlap.
      #
      # edit_data is a hash with:
      #   resolved_range: [s2, e2] — the range that was replaced
      #   delta: integer — the net character change (new_length - old_length)
      #   or new_range: [s2, s2 + new_length] — can derive delta from this
      def self.transform(range, edit_data)
        s, e = range
        edit_data = edit_data.transform_keys(&:to_s)
        delta = delta_of(edit_data)

        edit_before?(range, edit_data["resolved_range"]) ? [ s + delta, e + delta ] : [ s, e ]
      end

      # Whether an edit of [s2, e2] sits before range [s, e] (the range
      # shifts by the edit's delta) or after it (the range stays put).
      # Raises Conflict when they overlap.
      def self.edit_before?(range, edit_range)
        s, e = range
        s2, e2 = edit_range

        # Zero-width insert point: an edit ending at the point goes first,
        # one starting after it goes after, and one covering it conflicts.
        if s == e
          return true if e2 <= s
          return false if s2 > s

          raise Conflict, "Edit overlaps with insert point"
        end

        return true if e2 <= s
        return false if s2 >= e

        raise Conflict, "Ranges overlap: [#{s}, #{e}] conflicts with edit at [#{s2}, #{e2}]"
      end

      def self.delta_of(edit_data)
        if edit_data.key?("new_range")
          new_s2, new_e2 = edit_data["new_range"]
          s2, e2 = edit_data["resolved_range"]
          (new_e2 - new_s2) - (e2 - s2)
        elsif edit_data.key?("delta")
          edit_data["delta"].to_i
        else
          raise ArgumentError, "edit_data must contain 'new_range' or 'delta'"
        end
      end

      # +edit+ and +range_edit+ were both made against the same content.
      # Returns +edit+ as it applies after +range_edit+, and +range_edit+ as
      # it applies after +edit+. Their order is the one transform decides
      # for +range_edit+'s range moving through +edit+, so the pair agrees
      # with ranges already moved that way. Raises Conflict on overlap.
      def self.exchange(edit, range_edit)
        edit = edit.transform_keys(&:to_s)
        range_edit = range_edit.transform_keys(&:to_s)

        if edit_before?(range_edit["resolved_range"], edit["resolved_range"])
          [ shifted(edit, 0), shifted(range_edit, delta_of(edit)) ]
        else
          [ shifted(edit, delta_of(range_edit)), shifted(range_edit, 0) ]
        end
      end

      def self.shifted(edit, offset)
        s2, e2 = edit["resolved_range"]
        { "resolved_range" => [ s2 + offset, e2 + offset ], "delta" => delta_of(edit) }
      end
      private_class_method :shifted

      # Flatten versions' operations_json into one sequence of edits, each
      # relative to the content after the edit before it.
      #
      # versions: array of PlanVersion records (or hashes with operations_json),
      #   ordered by revision ascending
      def self.edits_from_versions(versions)
        versions.flat_map do |version|
          edits_from_operations(version.is_a?(Hash) ? version[:operations_json] || version["operations_json"] : version.operations_json)
        end
      end

      # Flatten one version's operations_json (or the :applied list from
      # Plans::ApplyOperations) into a sequence of edits.
      def self.edits_from_operations(operations)
        Array(operations).flat_map do |op_data|
          op_data = op_data.transform_keys(&:to_s)

          if op_data.key?("replacements")
            # replace_all: every replacement range is relative to the content
            # before the operation. Highest first, each one leaves the lower
            # ranges where they were.
            op_data["replacements"].map { |replacement| replacement.transform_keys(&:to_s) }
              .sort_by { |replacement| -replacement["resolved_range"][0] }
          elsif op_data.key?("resolved_range")
            [ op_data ]
          else
            raise Conflict, "Operation lacks positional metadata (resolved_range or replacements)"
          end
        end
      end

      def self.transform_through_edits(range, edits)
        edits.reduce(range.dup) { |current_range, edit| transform(current_range, edit) }
      end

      # Transform a range through the edits of a sequence of versions.
      # Returns the transformed range or raises Conflict.
      def self.transform_through_versions(range, versions)
        transform_through_edits(range, edits_from_versions(versions))
      end

      # An insertion strictly inside a comment's range is unambiguous even
      # when the editor saves several typed characters as one operation.
      # A deletion strictly inside the range is also positionally clear;
      # the caller checks how much recognizable text remains. Other broad
      # replacements invalidate the quote rather than moving it elsewhere.
      def self.transform_comment_through_versions(range, versions)
        current = range.dup
        touched = false
        edits_from_versions(versions).each do |edit|
          raise Conflict, "Operation lacks replacement length" unless edit.key?("new_range") || edit.key?("delta")
          begin
            current = transform(current, edit)
          rescue Conflict
            s, e = current
            s2, e2 = edit.fetch("resolved_range")
            old_text = edit["old_text"].to_s
            new_text = edit["new_text"].to_s
            inside = s2 >= s && e2 <= e && (s2 > s || e2 < e)
            insertion = s2 == e2 && old_text.empty? && s < s2 && s2 < e
            deletion = new_text.empty? && old_text.present? && s < s2 && e2 < e && e2 - s2 == old_text.length
            small_replacement = old_text.length + new_text.length <= 8 && e2 - s2 == old_text.length
            raise unless inside && (insertion || deletion || small_replacement)
            current = [ s, e + new_text.length - old_text.length ]
            touched = true
          end
        end
        [ current, touched ]
      end
    end
  end
end
