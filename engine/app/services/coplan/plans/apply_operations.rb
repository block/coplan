module CoPlan
  module Plans
    class ApplyOperations
      def self.call(content:, operations:)
        new(content:, operations:).call
      end

      def initialize(content:, operations:)
        @content = content.dup
        @operations = operations
        @applied = []
      end

      def call
        @operations.each_with_index do |op, index|
          op = op.transform_keys(&:to_s)
          applied_data = case op["op"]
          when "replace_exact"
            apply_replace_exact(op, index)
          when "insert_under_heading"
            apply_insert_under_heading(op, index)
          when "delete_paragraph_containing"
            apply_delete_paragraph_containing(op, index)
          else
            raise OperationError, "Operation #{index}: unknown op '#{op["op"]}'"
          end
          @applied << applied_data
        end

        { content: @content, applied: @applied }
      end

      private

      def apply_replace_exact(op, index)
        old_text = op["old_text"]
        new_text = op["new_text"]

        raise OperationError, "Operation #{index}: replace_exact requires 'old_text'" if old_text.blank?
        raise OperationError, "Operation #{index}: replace_exact requires 'new_text'" if new_text.nil?

        ranges = if op.key?("_pre_resolved_ranges")
          op["_pre_resolved_ranges"]
        else
          Plans::PositionResolver.call(content: @content, operation: op).ranges
        end

        applied_data = op.except("_pre_resolved_ranges")

        if ranges.length > 1
          replacements = []
          cumulative_delta = 0

          ranges.sort_by { |r| r[0] }.each do |range|
            adjusted_start = range[0] + cumulative_delta
            adjusted_end = range[1] + cumulative_delta

            @content = @content[0...adjusted_start] + new_text + @content[adjusted_end..]

            delta = new_text.length - old_text.length
            replacements << {
              "resolved_range" => range,
              "new_range" => [range[0], range[0] + new_text.length],
              "delta" => delta
            }
            cumulative_delta += delta
          end

          applied_data["replacements"] = replacements
          applied_data["total_delta"] = cumulative_delta
        else
          range = ranges[0]
          @content = @content[0...range[0]] + new_text + @content[range[1]..]

          delta = new_text.length - old_text.length
          applied_data["resolved_range"] = range
          applied_data["new_range"] = [range[0], range[0] + new_text.length]
          applied_data["delta"] = delta
        end

        applied_data
      end

      def apply_insert_under_heading(op, index)
        heading = op["heading"]

        raise OperationError, "Operation #{index}: insert_under_heading requires 'heading'" if heading.blank?
        raise OperationError, "Operation #{index}: insert_under_heading requires 'content'" if op["content"].nil?

        insert_point = if op.key?("_pre_resolved_ranges")
          op["_pre_resolved_ranges"][0]
        else
          Plans::PositionResolver.call(content: @content, operation: op).ranges[0]
        end
        content_to_insert = "\n" + op["content"]

        @content = @content[0...insert_point[0]] + content_to_insert + @content[insert_point[1]..]

        applied_data = op.except("_pre_resolved_ranges")
        applied_data["resolved_range"] = insert_point
        applied_data["new_range"] = [insert_point[0], insert_point[0] + content_to_insert.length]
        applied_data["delta"] = content_to_insert.length
        applied_data
      end

      def apply_delete_paragraph_containing(op, index)
        needle = op["needle"]

        raise OperationError, "Operation #{index}: delete_paragraph_containing requires 'needle'" if needle.blank?

        range = if op.key?("_pre_resolved_ranges")
          op["_pre_resolved_ranges"][0]
        else
          Plans::PositionResolver.call(content: @content, operation: op).ranges[0]
        end

        deleted_length = range[1] - range[0]
        @content = @content[0...range[0]] + @content[range[1]..]

        applied_data = op.except("_pre_resolved_ranges")
        applied_data["resolved_range"] = range
        applied_data["new_range"] = [range[0], range[0]]
        applied_data["delta"] = -deleted_length
        applied_data
      end
    end
  end
end
