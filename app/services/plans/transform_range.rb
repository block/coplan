module Plans
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

      s2, e2 = edit_data["resolved_range"]

      # Calculate delta from the edit
      if edit_data.key?("new_range")
        new_s2, new_e2 = edit_data["new_range"]
        delta = (new_e2 - new_s2) - (e2 - s2)
      elsif edit_data.key?("delta")
        delta = edit_data["delta"].to_i
      else
        raise ArgumentError, "edit_data must contain 'new_range' or 'delta'"
      end

      # Zero-width insert point: special handling
      if s == e
        # Insert point: shift if edit is strictly before
        if e2 <= s
          return [s + delta, e + delta]
        elsif s2 > s
          return [s, e]
        else
          raise Conflict, "Edit overlaps with insert point"
        end
      end

      # Case 1: Edit is entirely before our range (e2 <= s)
      if e2 <= s
        return [s + delta, e + delta]
      end

      # Case 2: Edit is entirely after our range (s2 >= e)
      if s2 >= e
        return [s, e]
      end

      # Case 3: Overlap — conflict
      raise Conflict, "Ranges overlap: [#{s}, #{e}] conflicts with edit at [#{s2}, #{e2}]"
    end

    # Transform a range through a sequence of edits from a PlanVersion.
    # Each version has operations_json with resolved position data.
    #
    # versions: array of PlanVersion records (or hashes with operations_json),
    #   ordered by revision ascending
    # Returns the transformed range or raises Conflict.
    def self.transform_through_versions(range, versions)
      current_range = range.dup

      versions.each do |version|
        ops = version.is_a?(Hash) ? version[:operations_json] || version["operations_json"] : version.operations_json
        next if ops.blank?

        ops.each do |op_data|
          op_data = op_data.transform_keys(&:to_s)

          if op_data.key?("replacements")
            # replace_all: multiple ranges, each shifts independently
            # Process in reverse order (highest position first) since each was
            # already adjusted for previous replacements during application
            op_data["replacements"].sort_by { |r| -r["resolved_range"][0] }.each do |replacement|
              current_range = transform(current_range, replacement)
            end
          elsif op_data.key?("resolved_range")
            current_range = transform(current_range, op_data)
          end
        end
      end

      current_range
    end
  end
end
